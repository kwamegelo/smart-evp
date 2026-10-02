function demo_single_run(seed)
%DEMO_SINGLE_RUN  Time-space diagrams: fixed-time vs EVP corridor.
%   demo_single_run        uses a "typical" seed (fixed-time delay closest to the mean of seeds 1..50)
%   demo_single_run(seed)  uses the seed you give
cfg = config_params();
if nargin < 1
    d = zeros(1,50);
    for s = 1:50, d(s) = run_simulation(cfg, 'fixed', s).ambDelay; end
    [~, seed] = min(abs(d - mean(d)));
end
fprintf('Demo seed: %d\n', seed);
rF = run_simulation(cfg, 'fixed', seed);
rC = run_simulation(cfg, 'evp', seed, struct('range', 'corridor'));
fprintf('Ambulance delay  fixed: %.1f s | EVP corridor: %.1f s\n', rF.ambDelay, rC.ambDelay);
fprintf('Ambulance stops  fixed: %d | EVP corridor: %d\n', rF.ambStops, rC.ambStops);
fprintf('Cross-road delay fixed: %.1f s | EVP corridor: %.1f s\n', rF.delayB, rC.delayB);

figure('Name', 'SMART-EVP time-space', 'Position', [100 100 1000 450]);
plot_timespace(subplot(1,2,1), rF, cfg, 'Fixed-time');
plot_timespace(subplot(1,2,2), rC, cfg, 'EVP corridor');
end

function plot_timespace(ax, res, cfg, ttl)
hold(ax, 'on'); t = res.trace.t;
for j = 1:cfg.nJunctions
    st = res.trace.state(j,:);
    g = (st == 1 | st == 7); y = (st == 2); r = ~(g | y);
    y0 = cfg.junctionPos(j);
    plot(ax, t(r), y0*ones(1,nnz(r)), '.', 'Color', [0.85 0.1 0.1], 'MarkerSize', 8);
    plot(ax, t(y), y0*ones(1,nnz(y)), '.', 'Color', [0.95 0.75 0.1], 'MarkerSize', 8);
    plot(ax, t(g), y0*ones(1,nnz(g)), '.', 'Color', [0.1 0.65 0.2], 'MarkerSize', 8);
end
plot(ax, t, res.trace.x, 'k', 'LineWidth', 1.8);
tEnd = min(cfg.simTime, res.ambTime + 15);
xlim(ax, [0 tEnd]); ylim(ax, [0 cfg.endPos]); grid(ax, 'on');
xlabel(ax, 'time [s]'); ylabel(ax, 'position [m]');
title(ax, sprintf('%s: %.1f s delay', ttl, res.ambDelay));
end
