function demo_two_ambulances(seed)
%DEMO_TWO_AMBULANCES  Patient ambulance on the corridor (road A) and an empty one crossing at J2 (road B).
if nargin < 1, seed = 7; end
cfg = config_params();
if ~strcmpi(cfg.amb2.mode, 'cross'), error('Set cfg.amb2.mode = ''cross'' for this demo.'); end
rF = run_simulation(cfg, 'fixed', seed, struct('twoAmb', true));
rE = run_simulation(cfg, 'evp', seed, struct('range', 'corridor', 'twoAmb', true));
for r = {rF, rE}
    q = r{1};
    fprintf('%-6s patient delay %5.1f s, %d stops | empty delay %5.1f s, %d stops | empty held %4.1f s\n', ...
        q.mode, q.amb(1).delay, q.amb(1).stops, q.amb(2).delay, q.amb(2).stops, q.heldSeconds(2));
end
figure('Name', 'Two ambulances', 'Position', [60 60 1100 620]);
plot_patient(subplot(2,2,1), rF, cfg, 'Fixed-time: patient (road A)');
plot_patient(subplot(2,2,2), rE, cfg, 'EVP: patient (road A)');
plot_empty(subplot(2,2,3), rF, cfg, 'Fixed-time: empty (road B at J2)');
plot_empty(subplot(2,2,4), rE, cfg, 'EVP: empty (road B at J2)');
end

function plot_patient(ax, res, cfg, ttl)
hold(ax, 'on'); t = res.trace.t;
for j = 1:cfg.nJunctions
    st = res.trace.state(j,:); g = (st == 1 | st == 7); y = (st == 2); rd = ~(g | y); y0 = cfg.junctionPos(j);
    plot(ax, t(rd), y0*ones(1,nnz(rd)), '.', 'Color', [0.85 0.1 0.1], 'MarkerSize', 8);
    plot(ax, t(y),  y0*ones(1,nnz(y)),  '.', 'Color', [0.95 0.75 0.1], 'MarkerSize', 8);
    plot(ax, t(g),  y0*ones(1,nnz(g)),  '.', 'Color', [0.1 0.65 0.2], 'MarkerSize', 8);
end
plot(ax, t, res.trace.x, 'k', 'LineWidth', 1.8);
xlim(ax, [0 min(cfg.simTime, res.amb(1).travelTime + 15)]); ylim(ax, [0 cfg.endPos]); grid(ax, 'on');
xlabel(ax, 'time [s]'); ylabel(ax, 'position [m]'); title(ax, sprintf('%s: %.1f s delay', ttl, res.amb(1).delay));
end

function plot_empty(ax, res, cfg, ttl)
hold(ax, 'on'); t = res.trace.t; j = cfg.amb2.junction;
st = res.trace.state(j,:); g = (st == 4 | st == 8); y = (st == 5); rd = ~(g | y); y0 = cfg.bStopPos;   % B-road lights
plot(ax, t(rd), y0*ones(1,nnz(rd)), '.', 'Color', [0.85 0.1 0.1], 'MarkerSize', 8);
plot(ax, t(y),  y0*ones(1,nnz(y)),  '.', 'Color', [0.95 0.75 0.1], 'MarkerSize', 8);
plot(ax, t(g),  y0*ones(1,nnz(g)),  '.', 'Color', [0.1 0.65 0.2], 'MarkerSize', 8);
on = res.trace.act2 > 0;
plot(ax, t(on), res.trace.x2(on), 'b', 'LineWidth', 1.8);
tp = res.amb(1).crossTimes(j);
if ~isnan(tp), xline(ax, tp, '--k', 'patient crosses', 'LabelVerticalAlignment', 'bottom'); end
xlim(ax, [cfg.amb2.startTime - 5, min(cfg.simTime, cfg.amb2.startTime + res.amb(2).travelTime + 15)]);
ylim(ax, [0 cfg.bStopPos + 200]); grid(ax, 'on');
xlabel(ax, 'time [s]'); ylabel(ax, 'position on road B [m]'); title(ax, sprintf('%s: %.1f s delay', ttl, res.amb(2).delay));
end
