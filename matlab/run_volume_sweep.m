function out = run_volume_sweep(nRuns)
%RUN_VOLUME_SWEEP  Fixed-time vs conventional EVP (fixed trigger) vs adaptive just-in-time EVP,
%   across traffic volumes. Same seeds in every strategy (paired comparison).
%   Report an advantage only where the confidence intervals support it.
if nargin < 1, nRuns = 20; end
base = config_params();
scale = [0.5 1 1.5 1.8];                       % multiples of the default arrival rate
names = {'Fixed-time', 'EVP fixed trigger', 'EVP adaptive'};
metrics = {'ambDelay','ambStops','delayB','preemptSeconds'};
labels  = {'Ambulance delay [s]','Ambulance stops','Cross-road delay [s]','Preemption time [s]'};
M = nan(numel(scale), nRuns, numel(metrics), 3);
for i = 1:numel(scale)
    cfg = base; cfg.lambdaA = base.lambdaA*scale(i); cfg.lambdaB = base.lambdaB*scale(i);
    for s = 1:nRuns
        rr = cell(1,3);
        rr{1} = run_simulation(cfg, 'fixed', s);
        rr{2} = run_simulation(cfg, 'evp', s, struct('range','corridor','leadMode','fixed'));
        rr{3} = run_simulation(cfg, 'evp', s, struct('range','corridor','leadMode','adaptive'));
        for c = 1:3, for m = 1:numel(metrics), M(i,s,m,c) = rr{c}.(metrics{m}); end, end
    end
end
mu = nan(numel(scale), numel(metrics), 3); ci = mu;
fprintf('\n====== VOLUME SWEEP (%d runs each, mean +/- 95%% CI) ======\n', nRuns);
for m = 1:numel(metrics)
    fprintf('\n%s\n%-10s', labels{m}, 'volume x');  fprintf('%-24s', names{:}); fprintf('\n');
    for i = 1:numel(scale)
        fprintf('%-10.1f', scale(i));
        for c = 1:3
            [mu(i,m,c), ci(i,m,c)] = summary_stats(reshape(M(i,:,m,c), [], 1));
            fprintf('%8.2f +/- %-10.2f  ', mu(i,m,c), ci(i,m,c));
        end
        fprintf('\n');
    end
end
figure('Name', 'Volume sweep', 'Position', [80 80 1000 640]);
col = [0.88 0.4 0.23; 0.88 0.66 0.23; 0.18 0.68 0.35];
for m = 1:numel(metrics)
    ax = subplot(2,2,m); hold(ax, 'on');
    for c = 1:3
        errorbar(ax, scale, squeeze(mu(:,m,c)), squeeze(ci(:,m,c)), '-o', 'Color', col(c,:), 'LineWidth', 1.6);
    end
    xlabel(ax, 'traffic volume (x default)'); title(ax, labels{m}); grid(ax, 'on');
    if m == 1, legend(ax, names, 'Location', 'best'); end
end
if ~exist('results', 'dir'), mkdir('results'); end
rows = {}; 
for i = 1:numel(scale), for m = 1:numel(metrics), for c = 1:3
    rows(end+1,:) = {scale(i), metrics{m}, names{c}, mu(i,m,c), ci(i,m,c)}; %#ok<AGROW>
end, end, end
writetable(cell2table(rows, 'VariableNames', {'volume','metric','strategy','mean','ci95'}), fullfile('results','volume_sweep.csv'));
out.scale = scale; out.mean = mu; out.ci = ci; out.names = names; out.metrics = metrics;
end
