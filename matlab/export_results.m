function export_results(nRuns, outFile)
%EXPORT_RESULTS  Monte Carlo summary (mean and 95% CI) as JSON for the dashboard charts page.
if nargin < 1, nRuns = 50; end
if nargin < 2, outFile = 'results_summary.json'; end
cfg = config_params();
names  = {'Fixed-time', 'EVP local range', 'EVP corridor'};
keys   = {'ambDelay','ambStops','delayB','delayA','maxQueue','recoveryMean'};
labels = {'Ambulance delay (s)','Ambulance stops','Cross-road delay (s)','Main-road delay (s)','Max queue (veh)','Recovery time (s)'};
D = nan(nRuns, numel(keys), 3);
for s = 1:nRuns
    r1 = run_simulation(cfg, 'fixed', s);
    r2 = run_simulation(cfg, 'evp', s, struct('range','local'));
    r3 = run_simulation(cfg, 'evp', s, struct('range','corridor'));
    rr = {r1, r2, r3};
    for c = 1:3, for m = 1:numel(keys), D(s,m,c) = rr{c}.(keys{m}); end, end
end
out.nRuns = nRuns; out.scenarios = names;
for m = 1:numel(keys)
    mu = nan(1,3); ci = nan(1,3);
    for c = 1:3, [mu(c), ci(c)] = summary_stats(D(:,m,c)); end
    out.metrics(m) = struct('key', keys{m}, 'label', labels{m}, 'mean', mu, 'ci', ci);
end
o2 = run_two_ambulance_experiments(min(nRuns, 30));
sel = [1 2 5 6]; lab = {'Patient delay (s)','Empty ambulance delay (s)','Cross-road delay (s)','Empty held by priority (s)'};
out.twoAmb.scenarios = o2.names;
for k = 1:numel(sel)
    out.twoAmb.metrics(k) = struct('key', o2.metrics{sel(k)}, 'label', lab{k}, ...
        'mean', o2.mean(:,sel(k)).', 'ci', o2.ci(:,sel(k)).');
end
ov = run_volume_sweep(min(nRuns, 20));                       % traffic-volume sweep (line charts)
vlab = {'Ambulance delay (s)','Ambulance stops','Cross-road delay (s)','Preemption time (s)'};
out.volume.scale = ov.scale; out.volume.scenarios = ov.names;
for m = 1:numel(vlab)
    out.volume.metrics(m) = struct('key', ov.metrics{m}, 'label', vlab{m}, ...
        'mean', squeeze(ov.mean(:,m,:)), 'ci', squeeze(ov.ci(:,m,:)));
end
fid = fopen(outFile, 'w'); fwrite(fid, jsonencode(out), 'char'); fclose(fid);
fprintf('Exported %s (load it in dashboard.html)\n', outFile);
end
