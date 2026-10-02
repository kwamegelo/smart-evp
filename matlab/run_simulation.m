function res = run_simulation(cfg, mode, seed, opts)
%RUN_SIMULATION  Discrete-time simulation of ambulance(s) crossing a signalised corridor.
%
%   res = run_simulation(cfg, 'fixed', seed)            fixed-time signals, no priority
%   res = run_simulation(cfg, 'evp',   seed, opts)      secure EVP (emergency vehicle preemption)
%
%   opts fields (all optional):
%     range          'local' (default) | 'corridor'   radio range / pre-notification
%     security       true (default) | false           verify HMAC/freshness/replay
%     twoAmb         false (default) | true           add AMB-002 (empty ambulance), see cfg.amb2
%     leadMode       'fixed' (default: trigger at ETA <= cfg.leadTime) | 'adaptive' (just-in-time:
%                    trigger when the junction needs exactly the time to reach green + flush the queue)
%     attack         'none' | 'badsig' | 'unregistered' | 'replay' | 'stale'
%     attackJunction junction index targeted (default 2)
%     attackWindow   [t0 t1] seconds (default [8 38])
%     blackout       [t0 t1] ambulances send nothing (GPS/radio dropout)
%     stuckAt        [x duration] patient ambulance is blocked at position x for duration s
%     operator       struct array with fields t [s], junction, cmd = 'cancel' (no preemption),
%                    'force_A' / 'force_B' (emergency green for that road) or 'release'
%
%   Priority: the junction looks the vehicle ID up in its own registry (cfg.prio), so a
%   vehicle cannot claim a higher priority. Patient (2) beats empty (1). If they conflict
%   (road A vs road B) the patient is served first, except that an ambulance already
%   within cfg.commitDist of the stop line keeps its green until it has cleared.
%
%   Same seed => identical traffic arrivals in every mode (paired comparison).

if nargin < 4 || isempty(opts), opts = struct(); end
opts = apply_defaults(opts);
useEVP = strcmpi(mode, 'evp');
if strcmpi(opts.range, 'corridor'), radio = cfg.rangeCorridor; else, radio = cfg.rangeLocal; end

% signal states (EV = emergency green on road A, EB = emergency green on road B)
S_AG = 1; S_AY = 2; S_AR1 = 3; S_BG = 4; S_BY = 5; S_AR2 = 6; S_EV = 7; S_EB = 8;
allowed = false(8,8);
allowed(S_AG,[S_AY S_EV]) = true;    allowed(S_EV,S_AY) = true;
allowed(S_AY,S_AR1) = true;          allowed(S_AR1,[S_BG S_EV S_EB]) = true;
allowed(S_BG,[S_BY S_EB]) = true;    allowed(S_EB,S_BY) = true;
allowed(S_BY,S_AR2) = true;          allowed(S_AR2,[S_AG S_EV S_EB]) = true;

dt = cfg.dt; nSteps = round(cfg.simTime/dt); J = cfg.nJunctions; pos = cfg.junctionPos;
A = make_ambulances(cfg, opts); na = numel(A); ids = {A.id}; t0v = [A.t0];
rsT = RandStream('mt19937ar', 'Seed', seed);            % traffic stream
rsCv = cell(1,na);                                      % one communication stream per ambulance
for a = 1:na, rsCv{a} = RandStream('mt19937ar', 'Seed', seed + 100000 + 1000*(a-1)); end

% ---- signal initial conditions (random phase offset per junction) ----
dur = [cfg.greenA cfg.yellow cfg.allRed cfg.greenB cfg.yellow cfg.allRed];
state = zeros(1,J); tIn = zeros(1,J);
for j = 1:J
    o = rand(rsT) * sum(dur); k = 1;
    while o >= dur(k), o = o - dur(k); k = k + 1; end
    state(j) = k; tIn(j) = o;
end
bDur = cfg.greenB * ones(1,J); aDur = cfg.greenA * ones(1,J);
recov = false(1,J); recovA = false(1,J);

% ---- traffic ----
qA = zeros(1,J); qB = zeros(1,J); accA = zeros(1,J); accB = zeros(1,J);
arrA = zeros(1,J); arrB = zeros(1,J); qSecA = zeros(1,J); qSecB = zeros(1,J); qMax = 0;

% ---- EVP bookkeeping: one row per junction, one column per ambulance ----
engaged = false(J,na); engStart = nan(J,na); lastRx = -inf(J,na); lastDist = inf(J,na);
done = false(J,na); isAtk = false(J,na); reqDir = ones(J,na);
relTime = nan(1,J); recTime = nan(1,J); prevP = zeros(1,J); heldSec = zeros(1,na);
lastSeq = cell(1,J);
for j = 1:J, lastSeq{j} = containers.Map('KeyType','char','ValueType','double'); end
rejects = struct('unregistered',0,'bad_signature',0,'stale',0,'replay',0);
nAccepted = 0; lostMsgs = 0; preemptCount = 0; preemptSec = 0; spoofedEng = 0; spoofedSec = 0;
watchdog = 0; dropoutRel = 0; exitRel = 0; conflicts = 0; illegal = 0; redRuns = 0; ignoredEmpty = 0;
seqNo = zeros(1,na); hist = {};
ops = opts.operator; if ~isempty(ops), [~,ix] = sort([ops.t]); ops = ops(ix); end
opNext = 1; opState = zeros(1,J); opEvents = struct('t',{},'junction',{},'cmd',{});

% ---- ambulances ----
x = zeros(1,na); v = cfg.vAmb*ones(1,na); passed = false(na,J); crossT = nan(na,J);
stops = zeros(1,na); stoppedT = zeros(1,na); wasStopped = false(1,na);
finished = false(1,na); tFin = nan(1,na); stuckDone = false; stuckT0 = NaN;

% ---- trace (x,v = patient ambulance; x2,v2,act2 = second ambulance) ----
tr.t = zeros(1,nSteps); tr.x = zeros(1,nSteps); tr.v = zeros(1,nSteps);
tr.x2 = zeros(1,nSteps); tr.v2 = zeros(1,nSteps); tr.act2 = zeros(1,nSteps);
tr.state = zeros(J,nSteps); tr.qA = zeros(J,nSteps); tr.qB = zeros(J,nSteps);
tr.engaged = zeros(J,nSteps); tr.pdir = zeros(J,nSteps);

for k = 1:nSteps
    t = (k-1) * dt;
    gA = (state == S_AG) | (state == S_EV);
    gB = (state == S_BG) | (state == S_EB);
    active = (t >= t0v) & ~finished;

    % 1) normal-traffic arrivals (Bernoulli per step) -------------------------
    r = rand(rsT, 1, 2*J);
    for j = 1:J
        if r(j) < cfg.lambdaA*dt
            arrA(j) = arrA(j) + 1;
            if ~(gA(j) && qA(j) == 0 && tIn(j) >= cfg.startupLost), qA(j) = qA(j) + 1; end
        end
        if r(J+j) < cfg.lambdaB*dt
            arrB(j) = arrB(j) + 1;
            if ~(gB(j) && qB(j) == 0 && tIn(j) >= cfg.startupLost), qB(j) = qB(j) + 1; end
        end
    end

    % 2) queue discharge on green ---------------------------------------------
    for j = 1:J
        if gA(j) && tIn(j) >= cfg.startupLost
            accA(j) = accA(j) + cfg.satFlow*dt; n = min(floor(accA(j)), qA(j));
            qA(j) = qA(j) - n; accA(j) = accA(j) - n; if qA(j) == 0, accA(j) = 0; end
        else, accA(j) = 0; end
        if gB(j) && tIn(j) >= cfg.startupLost
            accB(j) = accB(j) + cfg.satFlow*dt; n = min(floor(accB(j)), qB(j));
            qB(j) = qB(j) - n; accB(j) = accB(j) - n; if qB(j) == 0, accB(j) = 0; end
        else, accB(j) = 0; end
    end
    qSecA = qSecA + qA*dt; qSecB = qSecB + qB*dt; qMax = max([qMax qA qB]);
    conflicts = conflicts + sum(gA & gB);

    % 3) messages: legitimate ambulances + optional attacker -------------------
    inJ = zeros(1,0); inM = {};
    if useEVP && any(active)
        tick = abs(t/cfg.msgPeriod - round(t/cfg.msgPeriod)) < 1e-9;
        blk  = ~isempty(opts.blackout) && t >= opts.blackout(1) && t < opts.blackout(2);
        atk  = ~strcmp(opts.attack,'none') && t >= opts.attackWindow(1) && t <= opts.attackWindow(2);
        if tick
            if ~blk
                for a = 1:na
                    if ~active(a), continue; end
                    seqNo(a) = seqNo(a) + 1;
                    dch = 'A'; if A(a).road == 2, dch = 'B'; end
                    m = sign_message(A(a).id, seqNo(a), t, x(a), v(a), dch, cfg.keys(A(a).id));
                    hist{end+1} = m; %#ok<AGROW>
                    for jr = 1:numel(A(a).route)
                        j = A(a).route(jr); d = A(a).stopS(jr) - x(a);
                        if d > 0 && d <= radio
                            if rand(rsCv{a}) < cfg.pLoss
                                lostMsgs = lostMsgs + 1;
                            else
                                inJ(end+1) = j; inM{end+1} = m; %#ok<AGROW>
                                if atk && strcmp(opts.attack,'replay')      % duplicate of the same packet
                                    dup = m; dup.src = 'attacker';
                                    inJ(end+1) = j; inM{end+1} = dup; %#ok<AGROW>
                                end
                            end
                        end
                    end
                end
            end
            if atk
                aj = opts.attackJunction;
                xc = pos(aj) - 200 + 8*(t - opts.attackWindow(1));   % forged approaching position
                forged = [];
                switch opts.attack
                    case 'badsig'
                        forged = sign_message(cfg.ambId, 9000+k, t, xc, 12, 'A', cfg.attackerKey);
                    case 'unregistered'
                        forged = sign_message('AMB-999', k, t, xc, 12, 'A', 'unknown-key');
                    case 'stale'
                        if ~isempty(hist)
                            idx = find(cellfun(@(h) h.ts <= t - (cfg.maxMsgAge + 1), hist), 1, 'last');
                            if ~isempty(idx), forged = hist{idx}; end
                        end
                end
                if ~isempty(forged)
                    forged.src = 'attacker';
                    inJ(end+1) = aj; inM{end+1} = forged; %#ok<AGROW>
                end
            end
        end
    end

    % 4) junction controllers process messages ----------------------------------
    for i = 1:numel(inJ)
        j = inJ(i); m = inM{i};
        if opts.security
            [ok, reason] = verify_message(m, cfg, t, lastSeq{j});
        else
            ok = true; reason = 'ok';
        end
        if ~ok
            rejects.(reason) = rejects.(reason) + 1; continue;
        end
        nAccepted = nAccepted + 1;
        a = find(strcmp(ids, m.id), 1); if isempty(a), a = 1; end
        dn = 1 + strcmp(m.dir, 'B');                       % requested road: 1 = A, 2 = B
        if dn == 1, sj = pos(j); else, sj = cfg.bStopPos; end
        d = sj - m.x;
        approaching = d < lastDist(j,a);                   % distance must be reducing to START a request
        notReceding = d <= lastDist(j,a) + 0.5;            % a waiting (stopped) ambulance keeps its request alive
        lastDist(j,a) = d;
        if d > 0 && notReceding && (strcmp(m.dir,'A') || strcmp(m.dir,'B'))
            if prio_of(cfg, m.id) < 2 && ~cfg.emptyGetsPriority
                ignoredEmpty = ignoredEmpty + 1;           % empty ambulance gets no preemption
            else
                lastRx(j,a) = t;
                eta = d / max(m.v, cfg.minEtaSpeed);
                if approaching && ~done(j,a) && ~engaged(j,a) && engage_ok(opts.leadMode, cfg, state(j), tIn(j), aDur(j), bDur(j), dn, qA(j), qB(j), eta)
                    engaged(j,a) = true; engStart(j,a) = t; reqDir(j,a) = dn;
                    preemptCount = preemptCount + 1;
                    isAtk(j,a) = strcmp(m.src, 'attacker');
                    if isAtk(j,a), spoofedEng = spoofedEng + 1; end
                end
            end
        end
    end

    % 5) release logic: exit sensor, message dropout, watchdog -----------------
    for j = 1:J
        for a = 1:na
            if engaged(j,a)
                if reqDir(j,a) == 1, sj = pos(j); else, sj = cfg.bStopPos; end
                rel = '';
                if x(a) >= sj + cfg.exitMargin,              rel = 'exit';
                elseif t - lastRx(j,a) > cfg.dropoutTimeout, rel = 'dropout';
                elseif t - engStart(j,a) > cfg.maxPreempt,   rel = 'watchdog'; end
                if ~isempty(rel)
                    engaged(j,a) = false; isAtk(j,a) = false;
                    switch rel
                        case 'exit',     done(j,a) = true; exitRel = exitRel + 1;
                        case 'dropout',  dropoutRel = dropoutRel + 1;
                        case 'watchdog', watchdog = watchdog + 1;
                    end
                end
            end
        end
    end

    % 6) arbitration: which road (if any) does each junction serve? ------------
    pdir = zeros(1,J);
    for j = 1:J
        cand = find(engaged(j,:));
        if isempty(cand), continue; end
        score = -inf; best = cand(1);
        for c = cand                                       % highest priority, then earliest request
            sc = prio_of(cfg, A(c).id)*1e6 - engStart(j,c);
            if sc > score, score = sc; best = c; end
        end
        dsel = reqDir(j,best);
        curDir = (state(j) == S_EV)*1 + (state(j) == S_EB)*2;
        if curDir > 0 && dsel ~= curDir                    % don't cut off an ambulance about to cross
            for c = cand
                if reqDir(j,c) == curDir
                    if curDir == 1, sj = pos(j); else, sj = cfg.bStopPos; end
                    if x(c) >= sj - cfg.commitDist && x(c) < sj + cfg.exitMargin, dsel = curDir; break; end
                end
            end
        end
        pdir(j) = dsel;
        for c = cand
            if reqDir(j,c) ~= dsel, heldSec(c) = heldSec(c) + dt; end
        end
    end
    while opNext <= numel(ops) && ops(opNext).t <= t        % operator console commands
        o = ops(opNext); opNext = opNext + 1;
        switch o.cmd
            case 'cancel',  opState(o.junction) = 1;
            case 'force_A', opState(o.junction) = 2;
            case 'force_B', opState(o.junction) = 3;
            case 'release', opState(o.junction) = 0;
        end
        opEvents(end+1) = struct('t', t, 'junction', o.junction, 'cmd', o.cmd); %#ok<AGROW>
    end
    for j = 1:J                                             % override wins; signals still pass yellow/all-red
        if opState(j) == 1, pdir(j) = 0; elseif opState(j) == 2, pdir(j) = 1; elseif opState(j) == 3, pdir(j) = 2; end
    end
    preemptSec = preemptSec + sum(pdir > 0)*dt;
    spoofedSec = spoofedSec + sum(any(engaged & isAtk, 2))*dt;
    for j = 1:J
        if prevP(j) > 0 && pdir(j) == 0, relTime(j) = t; recTime(j) = NaN; end
    end
    prevP = pdir;

    % 7) signal controllers -----------------------------------------------------
    for j = 1:J
        prev = state(j);
        [state(j), tIn(j), bDur(j), aDur(j), recov(j), recovA(j)] = step_signal( ...
            state(j), tIn(j), bDur(j), aDur(j), recov(j), recovA(j), pdir(j), qA(j), qB(j), cfg);
        if state(j) ~= prev && ~allowed(prev, state(j)), illegal = illegal + 1; end
        if ~isnan(relTime(j)) && isnan(recTime(j)) && t > relTime(j) && (qA(j) + qB(j)) <= cfg.recoveryQ
            recTime(j) = t - relTime(j);
        end
    end

    % 8) ambulance dynamics -----------------------------------------------------
    for a = 1:na
        if ~active(a), continue; end
        rt = A(a).route; ss = A(a).stopS; isStuck = false;
        if a == 1 && ~isempty(opts.stuckAt) && ~stuckDone && x(a) >= opts.stuckAt(1)
            if isnan(stuckT0), stuckT0 = t; end
            if t - stuckT0 < opts.stuckAt(2), isStuck = true; else, stuckDone = true; end
        end
        if isStuck
            v(a) = 0;
        else
            jr = find(~passed(a,1:numel(rt)), 1); vlim = cfg.vAmb; canGo = true; gR = true; yR = false; qm = 0;
            if ~isempty(jr)
                j = rt(jr); d = ss(jr) - x(a); st = state(j);
                if A(a).road == 1
                    gR = (st == S_AG || st == S_EV); yR = (st == S_AY); q = qA(j);
                else
                    gR = (st == S_BG || st == S_EB); yR = (st == S_BY); q = qB(j);
                end
                qm = q * cfg.vehLen * cfg.bypassFactor;
                if gR
                    if q > 0 && d < qm + 30, vlim = cfg.vQueue; end
                elseif yR && d <= v(a)^2/(2*cfg.decel) + 1
                    canGo = true;                                  % cannot stop safely: proceed on yellow
                else
                    canGo = false;
                    vlim = min(cfg.vAmb, sqrt(2*cfg.decel*max(d - qm - 1, 0)));   % brake to stop before queue/line
                end
            end
            vNew = min(v(a) + cfg.accel*dt, vlim);
            vNew = max(vNew, v(a) - cfg.decelMax*dt); v(a) = max(vNew, 0);
            xNew = x(a) + v(a)*dt;
            if ~canGo, xNew = min(xNew, max(x(a), ss(jr) - qm - 0.5)); end
            if ~isempty(jr) && xNew >= ss(jr)
                passed(a,jr) = true; crossT(a,jr) = t + dt;
                if ~(gR || yR), redRuns = redRuns + 1; end
            end
            x(a) = xNew;
        end
        stopped = v(a) < 0.5;
        if stopped, stoppedT(a) = stoppedT(a) + dt; end
        if stopped && ~wasStopped(a), stops(a) = stops(a) + 1; end
        wasStopped(a) = stopped;
        if x(a) >= A(a).endS, finished(a) = true; tFin(a) = t + dt; end
    end

    tr.t(k) = t; tr.x(k) = x(1); tr.v(k) = v(1); tr.state(:,k) = state(:);
    tr.qA(:,k) = qA(:); tr.qB(:,k) = qB(:); tr.engaged(:,k) = any(engaged,2); tr.pdir(:,k) = pdir(:);
    if na > 1, tr.x2(k) = x(2); tr.v2(k) = v(2); tr.act2(k) = active(2); end
end

% ---- results ----------------------------------------------------------------
for a = 1:na
    freeFlow = A(a).endS / cfg.vAmb;
    if finished(a), tt = tFin(a) - A(a).t0; else, tt = cfg.simTime - A(a).t0; end   % unfinished trips are penalised
    amb(a) = struct('id', A(a).id, 'patient', prio_of(cfg, A(a).id) >= 2, 'road', A(a).road, ...
        'finished', finished(a), 'travelTime', tt, 'delay', tt - freeFlow, 'stops', stops(a), ...
        'stoppedTime', stoppedT(a), 'crossTimes', crossT(a,:)); %#ok<AGROW>
end
res.mode = mode; res.seed = seed; res.opts = opts; res.amb = amb;
res.finished = amb(1).finished; res.ambTime = amb(1).travelTime; res.ambDelay = amb(1).delay;
res.ambStops = amb(1).stops; res.ambStoppedTime = amb(1).stoppedTime; res.crossTimes = amb(1).crossTimes;
res.allFinished = all(finished);
res.emptyDelay = NaN; res.emptyStops = NaN;
if na > 1, res.emptyDelay = amb(2).delay; res.emptyStops = amb(2).stops; end
res.opEvents = opEvents; res.heldSeconds = heldSec; res.ignoredEmptyMsgs = ignoredEmpty;
res.delayA = sum(qSecA) / max(sum(arrA), 1);
res.delayB = sum(qSecB) / max(sum(arrB), 1);
res.delayAll = (sum(qSecA) + sum(qSecB)) / max(sum(arrA) + sum(arrB), 1);
res.maxQueue = qMax;
res.recoveryTimes = recTime; res.recoveryMean = mean(recTime, 'omitnan');
res.preemptCount = preemptCount; res.preemptSeconds = preemptSec;
res.accepted = nAccepted; res.rejects = rejects; res.lostMsgs = lostMsgs;
res.spoofedEngagements = spoofedEng; res.spoofedSeconds = spoofedSec;
res.watchdogReleases = watchdog; res.dropoutReleases = dropoutRel; res.exitReleases = exitRel;
res.conflicts = conflicts; res.illegalTransitions = illegal; res.redRuns = redRuns;
res.maxSpeed = max([tr.v tr.v2]);
res.trace = tr;
end

% =============================================================================
function [st, ti, bd, ad, rc, ra] = step_signal(st, ti, bd, ad, rc, ra, pdir, qA, qB, cfg)
% One controller tick. A = ambulance corridor road, B = cross road.
% pdir: 0 = no preemption, 1 = emergency green for road A, 2 = emergency green for road B.
% Preemption never skips yellow / all-red when switching roads.
S_AG = 1; S_AY = 2; S_AR1 = 3; S_BG = 4; S_BY = 5; S_AR2 = 6; S_EV = 7; S_EB = 8;
ti = ti + cfg.dt;
switch st
    case S_AG
        if pdir == 1
            st = S_EV;                                       % A already green: hold it
        elseif (pdir == 2 && ti >= cfg.minGreen) || ti >= ad
            st = S_AY; ti = 0;
        end
    case S_EV
        if pdir ~= 1, st = S_AY; ti = 0; rc = true; end      % release -> yellow -> recovery for B
    case S_AY
        if ti >= cfg.yellow, st = S_AR1; ti = 0; end
    case S_AR1
        if ti >= cfg.allRed
            ti = 0;
            if pdir == 1
                st = S_EV;
            elseif pdir == 2
                st = S_EB;
            else
                st = S_BG;
                if rc   % adaptive recovery: serve the cross-road queue that built up
                    bd = min(cfg.maxRecoveryGreen, max(cfg.minGreen, ceil(qB/cfg.satFlow) + cfg.startupLost + 2));
                    rc = false;
                else
                    bd = cfg.greenB;
                end
            end
        end
    case S_BG
        if pdir == 2
            st = S_EB;                                       % B already green: hold it
        elseif (pdir == 1 && ti >= cfg.minGreen) || ti >= bd
            st = S_BY; ti = 0;
        end
    case S_EB
        if pdir ~= 2, st = S_BY; ti = 0; ra = true; end     % release -> yellow -> recovery for A
    case S_BY
        if ti >= cfg.yellow, st = S_AR2; ti = 0; end
    case S_AR2
        if ti >= cfg.allRed
            ti = 0;
            if pdir == 1
                st = S_EV;
            elseif pdir == 2
                st = S_EB;
            else
                st = S_AG;
                if ra
                    ad = min(cfg.maxRecoveryGreen, max(cfg.minGreen, ceil(qA/cfg.satFlow) + cfg.startupLost + 2));
                    ra = false;
                else
                    ad = cfg.greenA;
                end
            end
        end
end
end

function A = make_ambulances(cfg, opts)
% Route description for each ambulance: road (1 = A, 2 = B), junctions crossed, stop-line
% coordinates along its own road, end coordinate and departure time.
A(1) = struct('id', cfg.ambId, 'road', 1, 'route', 1:cfg.nJunctions, 'stopS', cfg.junctionPos, ...
              'endS', cfg.endPos, 't0', 0);
if opts.twoAmb
    if strcmpi(cfg.amb2.mode, 'cross')
        A(2) = struct('id', 'AMB-002', 'road', 2, 'route', cfg.amb2.junction, 'stopS', cfg.bStopPos, ...
                      'endS', cfg.bStopPos + 200, 't0', cfg.amb2.startTime);
    else
        A(2) = struct('id', 'AMB-002', 'road', 1, 'route', 1:cfg.nJunctions, 'stopS', cfg.junctionPos, ...
                      'endS', cfg.endPos, 't0', cfg.amb2.followDelay);
    end
end
end

function ok = engage_ok(mode, cfg, st, ti, ad, bd, dn, qA, qB, eta)
% Fixed mode: preempt once the ETA is under cfg.leadTime (how conventional EVP behaves).
% Adaptive mode: preempt just in time, using the junction's own state and queue:
%   - road not green: start when ETA <= time to reach green (rest of min-green + yellow + all-red)
%     + time to discharge the queue + margin, so the queue is flushed before the ambulance arrives;
%   - road already green: do nothing unless that green would end before the ambulance gets there.
if ~strcmp(mode, 'adaptive'), ok = eta <= cfg.leadTime; return; end
S_AG = 1; S_AY = 2; S_AR1 = 3; S_BG = 4; S_BY = 5; S_AR2 = 6; S_EV = 7; S_EB = 8;
if dn == 1, q = qA; green = (st == S_AG || st == S_EV); else, q = qB; green = (st == S_BG || st == S_EB); end
qm = q * cfg.vehLen * cfg.bypassFactor;
if green
    if st == S_EV || st == S_EB, ok = eta <= cfg.leadTime; return; end    % already preempted
    if dn == 1, R = ad - ti; else, R = bd - ti; end                     % green time left
    extra = 0; if q > 0, extra = (qm + 30)/cfg.vQueue - (qm + 30)/cfg.vAmb; end   % slowdown in the queue
    ok = (R <= eta + extra + cfg.adaptiveMargin) && (eta <= cfg.leadTime);
else
    switch st
        case {S_AG, S_BG},   wait = max(0, cfg.minGreen - ti) + cfg.yellow + cfg.allRed;
        case {S_AY, S_BY},   wait = max(0, cfg.yellow - ti) + cfg.allRed;
        case {S_AR1, S_AR2}, wait = max(0, cfg.allRed - ti);
        otherwise,           wait = cfg.yellow + cfg.allRed;
    end
    qt = 0; if q > 0, qt = min(40, q/cfg.satFlow + cfg.startupLost); end
    ok = eta <= wait + qt + cfg.adaptiveMargin;
end
end

function p = prio_of(cfg, id)
% Priority from the junction's own registry; unknown IDs count as low priority.
if isKey(cfg.prio, id), p = cfg.prio(id); else, p = 1; end
end

function o = apply_defaults(o)
o = setdef(o, 'range', 'local');
o = setdef(o, 'security', true);
o = setdef(o, 'attack', 'none');
o = setdef(o, 'attackJunction', 2);
o = setdef(o, 'attackWindow', [8 38]);
o = setdef(o, 'twoAmb', false);
o = setdef(o, 'leadMode', 'fixed');
if ~isfield(o, 'blackout'), o.blackout = []; end
if ~isfield(o, 'operator'), o.operator = []; end
if ~isfield(o, 'stuckAt'),  o.stuckAt  = []; end
end

function o = setdef(o, f, val)
if ~isfield(o, f) || isempty(o.(f)), o.(f) = val; end
end
