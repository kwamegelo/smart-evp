function [m, ci, sd, n] = summary_stats(x)
%SUMMARY_STATS  Mean, 95% confidence half-width, std, count (NaNs ignored).
x = x(~isnan(x));  n = numel(x);
if n == 0, m = NaN; ci = NaN; sd = NaN; return; end
m = mean(x);  sd = std(x);
if n > 1, ci = tcrit(n-1) * sd / sqrt(n); else, ci = NaN; end
end

function t = tcrit(df)
if exist('tinv', 'file') == 2
    t = tinv(0.975, df);
else   % Cornish-Fisher approximation of the t quantile
    z = 1.959964;
    t = z + (z^3 + z)/(4*df) + (5*z^5 + 16*z^3 + 3*z)/(96*df^2);
end
end
