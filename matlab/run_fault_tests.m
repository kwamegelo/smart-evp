function T = run_fault_tests(nSeeds)
%RUN_FAULT_TESTS  Fault-injection and two-ambulance scenarios, each repeated over several seeds.
%   Every scenario must also keep the safety invariants: no conflicting greens,
%   no illegal signal transitions, ambulances never cross on red, speed never above cruise.
if nargin < 1, nSeeds = 10; end
base = config_params();
nJ = base.nJunctions;
id = @(c) c;
safe = @(r) r.conflicts == 0 && r.illegalTransitions == 0 && r.redRuns == 0 && r.maxSpeed <= base.vAmb + 1e-6;
both = @(r) r.amb(1).finished && r.amb(2).finished;
% adding the empty ambulance must not delay the patient (tolerance 2 s) nor hold it > 6 s
patientOk = @(r,b) r.amb(1).delay <= b.ambDelay + 2 && r.heldSeconds(1) <= 6;

chkNormal = @(r,~) safe(r) && r.finished && r.preemptCount >= nJ;
chkReplay = @(r,~) safe(r) && r.finished && r.rejects.replay > 0 && r.spoofedEngagements == 0;
chkBadSig = @(r,~) safe(r) && r.finished && r.rejects.bad_signature > 0 && r.spoofedEngagements == 0;
chkUnreg  = @(r,~) safe(r) && r.finished && r.rejects.unregistered > 0 && r.spoofedEngagements == 0;
chkStale  = @(r,~) safe(r) && r.finished && r.rejects.stale > 0 && r.spoofedEngagements == 0;
chkInsec  = @(r,~) r.spoofedEngagements > 0;            % control: attack SHOULD work without security
chkBlack  = @(r,~) safe(r) && r.finished && r.dropoutReleases >= 1;
chkStuck  = @(r,~) safe(r) && r.finished && r.watchdogReleases >= 1;
chkLoss   = @(r,~) safe(r) && r.finished;
chkTwo    = @(r,b) safe(r) && both(r) && patientOk(r,b);
chkConf   = @(r,b) chkTwo(r,b) && r.heldSeconds(2) > 0;      % the empty one really was held back
chkOper   = @(r,~) safe(r) && r.finished && numel(r.opEvents) >= 1;
chkNoPrio = @(r,b) safe(r) && both(r) && patientOk(r,b) && r.heldSeconds(2) == 0 ...
                   && r.ignoredEmptyMsgs > 0 && r.preemptCount >= nJ;

twoOpts = struct('range', 'corridor', 'twoAmb', true);
setLoss = @(c) setfield(c, 'pLoss', 0.5);
noPrio  = @(c) setfield(c, 'emptyGetsPriority', false);

sc = {};
sc(end+1,:) = {'Normal EVP (corridor range)',           struct('range','corridor'), id, chkNormal};
sc(end+1,:) = {'Replay attack',                         struct('range','local','attack','replay'), id, chkReplay};
sc(end+1,:) = {'Bad signature (forged request)',        struct('range','local','attack','badsig'), id, chkBadSig};
sc(end+1,:) = {'Unregistered vehicle ID',               struct('range','local','attack','unregistered'), id, chkUnreg};
sc(end+1,:) = {'Stale message re-sent',                 struct('range','local','attack','stale'), id, chkStale};
sc(end+1,:) = {'CONTROL: attack works if security off', struct('range','local','attack','badsig','security',false), id, chkInsec};
sc(end+1,:) = {'Radio/GPS dropout (8-16 s)',            struct('range','corridor','blackout',[8 16]), id, chkBlack};
sc(end+1,:) = {'Blocked exit (watchdog)',               struct('range','corridor','stuckAt',[base.junctionPos(1)-5 90]), id, chkStuck};
sc(end+1,:) = {'50% packet loss',                       struct('range','corridor'), setLoss, chkLoss};
sc(end+1,:) = {'2 ambulances: conflict at J2, patient wins',   twoOpts, id, chkConf};
sc(end+1,:) = {'2 ambulances: empty arrives first, preempted', twoOpts, @(c) with_amb2(c,'startTime',10), chkConf};
sc(end+1,:) = {'2 ambulances: empty already committed',        twoOpts, @(c) with_amb2(c,'startTime',6),  chkTwo};
sc(end+1,:) = {'2 ambulances: same road (follow)',             twoOpts, @(c) with_amb2(c,'mode','follow'), chkTwo};
sc(end+1,:) = {'2 ambulances: empty gets no priority',         twoOpts, noPrio, chkNoPrio};

sc(end+1,:) = {'Operator cancels preemption at J2',       struct('range','corridor','operator',struct('t',0,'junction',2,'cmd','cancel')), id, chkOper};
sc(end+1,:) = {'Operator forces road-B green at J1',      struct('range','corridor','operator',struct('t',5,'junction',1,'cmd','force_B')), id, chkOper};
sc(end+1,:) = {'Adaptive (just-in-time) trigger',            struct('range','corridor','leadMode','adaptive'), id, chkLoss};
sc(end+1,:) = {'Adaptive trigger + 2 ambulances (conflict)',  struct('range','corridor','twoAmb',true,'leadMode','adaptive'), id, chkConf};
nS = size(sc, 1); passed = zeros(nS,1); failSeeds = cell(nS,1);
fprintf('\n=========== FAULT INJECTION (%d seeds each) ===========\n', nSeeds);
for i = 1:nS
    for s = 1:nSeeds
        cfg = sc{i,3}(base); o = sc{i,2};
        r = run_simulation(cfg, 'evp', s, o);
        b = [];
        if isfield(o, 'twoAmb') && o.twoAmb       % baseline: same run without the empty ambulance
            b = run_simulation(cfg, 'evp', s, rmfield(o, 'twoAmb'));
        end
        if sc{i,4}(r, b), passed(i) = passed(i) + 1; else, failSeeds{i}(end+1) = s; end
    end
    if passed(i) == nSeeds, tag = 'PASS'; else, tag = 'FAIL'; end
    fprintf('[%s] %-48s %2d/%d\n', tag, sc{i,1}, passed(i), nSeeds);
    if ~isempty(failSeeds{i}), fprintf('       failing seeds: %s\n', mat2str(failSeeds{i})); end
end
T = table(sc(:,1), passed, repmat(nSeeds, nS, 1), 'VariableNames', {'Scenario','Passed','Runs'});
if ~exist('results', 'dir'), mkdir('results'); end
writetable(T, fullfile('results', 'fault_tests.csv'));
end

function c = with_amb2(c, field, value)
c.amb2.(field) = value;
end
