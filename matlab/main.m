%% main.m - SMART-EVP Simulation Launcher
clear; clc; close all;

% Initialize simulation parameters
cfg = config_params();
seed = 42;

%% Run Scenarios
fprintf('Running fixed-time simulation...\n');
resFixed = run_simulation(cfg, 'fixed', seed);

fprintf('Running EVP simulation (Local Range)...\n');
optsLocal = struct('range', 'local', 'security', true);
resEVP_Local = run_simulation(cfg, 'evp', seed, optsLocal);

fprintf('Running EVP simulation (Corridor Range)...\n');
optsCorridor = struct('range', 'corridor', 'security', true);
resEVP_Corridor = run_simulation(cfg, 'evp', seed, optsCorridor);

%% Display Comparison
fprintf('\n================ RESULTS ================\n');
fprintf('Fixed Delay:      %.2f s\n', resFixed.ambDelay);
fprintf('EVP Local Delay:  %.2f s\n', resEVP_Local.ambDelay);
fprintf('EVP Corridor:     %.2f s\n', resEVP_Corridor.ambDelay);