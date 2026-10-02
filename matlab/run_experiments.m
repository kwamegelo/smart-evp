%% run_experiments.m - Phase 4 Monte Carlo & Security Experiments
clear; clc; close all;

cfg = config_params();
nRuns = 50; % Number of Monte Carlo iterations (Phase 4)
seeds = 1000 + (1:nRuns);

% Preallocate metric arrays
delayFixed    = zeros(1, nRuns);
delayLocal    = zeros(1, nRuns);
delayCorridor = zeros(1, nRuns);

fprintf('Running %d Monte Carlo trials per scenario...\n', nRuns);

for i = 1:nRuns
    s = seeds(i);
    
    % 1. Fixed-time baseline
    rFix = run_simulation(cfg, 'fixed', s);
    delayFixed(i) = rFix.ambDelay;
    
    % 2. EVP Local preemption
    rLoc = run_simulation(cfg, 'evp', s, struct('range', 'local'));
    delayLocal(i) = rLoc.ambDelay;
    
    % 3. EVP Corridor pre-notification
    rCor = run_simulation(cfg, 'evp', s, struct('range', 'corridor'));
    delayCorridor(i) = rCor.ambDelay;
end

% Compute 95% Confidence Intervals using summary_stats.m
[mFix, ciFix] = summary_stats(delayFixed);
[mLoc, ciLoc] = summary_stats(delayLocal);
[mCor, ciCor] = summary_stats(delayCorridor);

fprintf('\n================ MONTE CARLO RESULTS (%d RUNS) ================\n', nRuns);
fprintf('Fixed-Time Baseline Delay : %6.2f ± %.2f s\n', mFix, ciFix);
fprintf('EVP Local Range Delay     : %6.2f ± %.2f s\n', mLoc, ciLoc);
fprintf('EVP Corridor Range Delay  : %6.2f ± %.2f s\n', mCor, ciCor);

%% Security Attack Scenario Verification (Phase 3/4)
fprintf('\n================ SECURITY ATTACK EVALUATION ================\n');
attacks = {'badsig', 'unregistered', 'replay', 'stale'};

for k = 1:numel(attacks)
    atk = attacks{k};
    optsAtk = struct('range', 'local', 'security', true, 'attack', atk, 'attackJunction', 2);
    resAtk = run_simulation(cfg, 'evp', 42, optsAtk);
    
    rejCount = sum(struct2array(resAtk.rejects));
    if resAtk.spoofedEngagements == 0 && rejCount > 0, status = 'PASS'; else, status = 'FAIL'; end
    fprintf('Attack Scenario: %-12s | Rejected Requests: %2d | Spoofed Engagements: %d | Status: %s\n', ...
        atk, rejCount, resAtk.spoofedEngagements, status);
end