function out = run_two_ambulance_experiments(nRuns)
%RUN_TWO_AMBULANCE_EXPERIMENTS  Monte Carlo comparison with a patient and an empty ambulance.
%   Fixed-time | EVP with both ambulances prioritised | EVP with patient-only priority.
if nargin < 1, nRuns = 50; end
cfg = config_params();  cfgPO = cfg;  cfgPO.emptyGetsPriority = false;
names   = {'Fixed-time', 'EVP both prioritised', 'EVP patient only'};
metrics = {'patientDelay','emptyDelay','patientStops','emptyStops','crossDelay','emptyHeld'};
data = nan(nRuns, numel(metrics), 3);  unsafe = zeros(1,3);
for s = 1:nRuns
    rs = cell(1,3);
    rs{1} = run_simulation(cfg,   'fixed', s, struct('twoAmb', true));
    rs{2} = run_simulation(cfg,   'evp',   s, struct('range','corridor','twoAmb',true));
    rs{3} = run_simulation(cfgPO, 'evp',   s, struct('range','corridor','twoAmb',true));
    for c = 1:3
        r = rs{c};
        data(s,:,c) = [r.amb(1).delay, r.amb(2).delay, r.amb(1).stops, r.amb(2).stops, r.delayB, r.heldSeconds(2)];
        unsafe(c) = unsafe(c) + r.conflicts + r.illegalTransitions + r.redRuns;
    end
end
mu = nan(3, numel(metrics)); ci = mu;
fprintf('\n=========== TWO AMBULANCES: %d RUNS, mean +/- 95%% CI ===========\n', nRuns);
fprintf('%-24s', 'Metric'); fprintf('%-22s', names{:}); fprintf('\n');
for m = 1:numel(metrics)
    fprintf('%-24s', metrics{m});
    for c = 1:3
        [mu(c,m), ci(c,m)] = summary_stats(data(:,m,c));
        fprintf('%8.2f +/- %-9.2f  ', mu(c,m), ci(c,m));
    end
    fprintf('\n');
end
fprintf('Safety violations (conflicts + illegal + red runs): %s\n', mat2str(unsafe));

figure('Name', 'Two-ambulance results', 'Position', [100 100 1000 380]);
sel = [1 2 5];  ttl = {'Patient ambulance delay [s]', 'Empty ambulance delay [s]', 'Cross-road delay [s]'};
for p = 1:3
    ax = subplot(1,3,p); hold(ax, 'on');
    bar(ax, 1:3, mu(:,sel(p)));  errorbar(ax, 1:3, mu(:,sel(p)), ci(:,sel(p)), 'k.', 'LineStyle', 'none');
    set(ax, 'XTick', 1:3, 'XTickLabel', names); xtickangle(ax, 20); title(ax, ttl{p}); grid(ax, 'on');
end
if ~exist('results', 'dir'), mkdir('results'); end
T = array2table(reshape(data, nRuns, []), 'VariableNames', ...
    strcat(repmat(metrics, 1, 3), '_', reshape(repmat({'fixed','both','patientOnly'}, numel(metrics), 1), 1, [])));
writetable(T, fullfile('results', 'two_ambulance_runs.csv'));
out.mean = mu; out.ci = ci; out.names = names; out.metrics = metrics; out.unsafe = unsafe;
end
