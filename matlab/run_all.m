%% run_all.m - SMART-EVP Master Simulation, Experiment & Dashboard Export Pipeline
%  Executes all core functions, Monte Carlo analysis, security tests, and JSON exports.

clear; clc; close all;

fprintf('=======================================================\n');
fprintf('       SMART-EVP SYSTEM PIPELINE & DASHBOARD EXPORT     \n');
fprintf('=======================================================\n\n');

%% 1. INITIALIZE PARAMETERS
cfg = config_params();
seed = 42;
outDir = './';

%% 1b. SECURITY UNIT TESTS
fprintf('[1/6] Running security unit tests...\n');
test_security();
fprintf('\n');

%% 2. SINGLE SCENARIO SIMULATIONS
fprintf('[2/6] Running single-run scenarios...\n');
resFixed = run_simulation(cfg, 'fixed', seed);
resLocal = run_simulation(cfg, 'evp', seed, struct('range', 'local'));
resCorridor = run_simulation(cfg, 'evp', seed, struct('range', 'corridor'));

fprintf('      Fixed-Time Delay : %6.2f s\n', resFixed.ambDelay);
fprintf('      EVP Local Delay  : %6.2f s\n', resLocal.ambDelay);
fprintf('      EVP Corridor     : %6.2f s\n', resCorridor.ambDelay);
resTwo = run_simulation(cfg, 'evp', seed, struct('range', 'corridor', 'twoAmb', true));
fprintf('      Two ambulances   : patient %6.2f s | empty %6.2f s (held %.1f s)\n\n', resTwo.ambDelay, resTwo.emptyDelay, resTwo.heldSeconds(2));

%% 3. MONTE CARLO EXPERIMENTS (PHASE 4)
nRuns = 50;
seeds = 1000 + (1:nRuns);
delayFixed = zeros(1, nRuns);
delayLocal = zeros(1, nRuns);
delayCorridor = zeros(1, nRuns);

fprintf('[3/6] Running %d Monte Carlo trials per scenario...\n', nRuns);
for i = 1:nRuns
    s = seeds(i);
    rFix = run_simulation(cfg, 'fixed', s);
    rLoc = run_simulation(cfg, 'evp', s, struct('range', 'local'));
    rCor = run_simulation(cfg, 'evp', s, struct('range', 'corridor'));
    
    delayFixed(i)    = rFix.ambDelay;
    delayLocal(i)    = rLoc.ambDelay;
    delayCorridor(i) = rCor.ambDelay;
end

[mFix, ciFix] = summary_stats(delayFixed);
[mLoc, ciLoc] = summary_stats(delayLocal);
[mCor, ciCor] = summary_stats(delayCorridor);

fprintf('\n================ MONTE CARLO RESULTS (%d RUNS) ================\n', nRuns);
fprintf('Fixed-Time Baseline Delay : %6.2f ± %.2f s\n', mFix, ciFix);
fprintf('EVP Local Range Delay     : %6.2f ± %.2f s\n', mLoc, ciLoc);
fprintf('EVP Corridor Range Delay  : %6.2f ± %.2f s\n', mCor, ciCor);
fprintf('===============================================================\n\n');

%% 4. SECURITY ATTACK EVALUATION (PHASE 3)
fprintf('[4/6] Evaluating security attack scenarios...\n');
attacks = {'badsig', 'unregistered', 'replay', 'stale'};

fprintf('================ SECURITY ATTACK EVALUATION ================\n');
for k = 1:numel(attacks)
    atk = attacks{k};
    optsAtk = struct('range', 'local', 'security', true, 'attack', atk, 'attackJunction', 2);
    resAtk = run_simulation(cfg, 'evp', seed, optsAtk);
    
    rejCount = sum(struct2array(resAtk.rejects));
    if resAtk.spoofedEngagements == 0 && rejCount > 0, status = 'PASS'; else, status = 'FAIL'; end
    fprintf('Attack Scenario: %-12s | Rejected Requests: %2d | Spoofed Engagements: %d | Status: %s\n', ...
        atk, rejCount, resAtk.spoofedEngagements, status);
end
fprintf('===============================================================\n\n');

%% 4b. FAULT INJECTION TESTS + TIME-SPACE DEMO
fprintf('[5/6] Running fault-injection tests and demo plots...\n');
faultT = run_fault_tests(10);
demo_single_run();
demo_two_ambulances();
export_results(50);   % Monte Carlo summary -> results_summary.json (dashboard charts)
fprintf('\n');

%% 5. DASHBOARD JSON DATASET EXPORTS (PHASE 5)
fprintf('[6/6] Exporting JSON feeds for web dashboard...\n');

export_feed(resFixed, fullfile(outDir, 'feed_fixed.json'));
export_feed(resLocal, fullfile(outDir, 'feed_evp_local.json'));
export_feed(resCorridor, fullfile(outDir, 'feed_evp_corridor.json'));
export_feed(resTwo, fullfile(outDir, 'feed_evp_two_amb.json'));
resAdapt = run_simulation(cfg, 'evp', seed, struct('range', 'corridor', 'leadMode', 'adaptive'));
export_feed(resAdapt, fullfile(outDir, 'feed_evp_adaptive.json'));

% Export Security Event Log (Replay Attack)
optsAtkReplay = struct('range', 'local', 'security', true, 'attack', 'replay', 'attackJunction', 2);
resAttackReplay = run_simulation(cfg, 'evp', seed, optsAtkReplay);

secEvents = struct(...
    'timestamp', char(datetime('now')), ...
    'attackType', 'replay', ...
    'targetJunction', optsAtkReplay.attackJunction, ...
    'rejectedCounts', resAttackReplay.rejects, ...
    'spoofedEngagements', resAttackReplay.spoofedEngagements ...
);

fid = fopen(fullfile(outDir, 'security_events.json'), 'w');
if fid ~= -1
    fwrite(fid, jsonencode(secEvents), 'char');
    fclose(fid);
    fprintf('Exported isolated security event log to security_events.json\n');
end

fprintf('\n>>> PIPELINE EXECUTION COMPLETE! All feeds ready for React/Dashboard. <<<\n');
