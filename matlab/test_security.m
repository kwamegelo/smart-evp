function test_security()
%TEST_SECURITY  Unit tests for HMAC signing, tamper, replay, stale and unregistered requests.
cfg = config_params();
R = {};
newMap = @() containers.Map('KeyType','char','ValueType','double');

% 1) HMAC-SHA256 known test vector (RFC-style: key="key", msg="The quick brown fox...")
h = hmac_sha256('key', 'The quick brown fox jumps over the lazy dog');
R = chk(R, 'HMAC-SHA256 known test vector', strcmp(h, 'f7bc83f430538424b13298e6aa6fb143ef4d59a14946175997479dbc2d1a3cd8'));

key = cfg.keys(cfg.ambId);
m1 = sign_message(cfg.ambId, 1, 10, 100, 15, 'A', key);
L = newMap();
[ok, why] = verify_message(m1, cfg, 10.2, L);
R = chk(R, 'valid signed message accepted', ok && strcmp(why, 'ok'));

[ok, why] = verify_message(m1, cfg, 10.4, L);
R = chk(R, 'duplicate (replay) rejected', ~ok && strcmp(why, 'replay'));

m2 = sign_message(cfg.ambId, 2, 11, 120, 15, 'A', key);
[ok, ~] = verify_message(m2, cfg, 11.1, L);
R = chk(R, 'next sequence number accepted', ok);

m0 = sign_message(cfg.ambId, 1, 12, 140, 15, 'A', key);
[ok, why] = verify_message(m0, cfg, 12.1, L);
R = chk(R, 'sequence rollback rejected', ~ok && strcmp(why, 'replay'));

mt = sign_message(cfg.ambId, 3, 13, 160, 15, 'A', key);
mt.x = 10;                                   % tamper after signing
[ok, why] = verify_message(mt, cfg, 13.1, L);
R = chk(R, 'tampered position rejected', ~ok && strcmp(why, 'bad_signature'));

mw = sign_message(cfg.ambId, 4, 14, 180, 15, 'A', cfg.attackerKey);
[ok, why] = verify_message(mw, cfg, 14.1, L);
R = chk(R, 'wrong key rejected', ~ok && strcmp(why, 'bad_signature'));

mu = sign_message('AMB-999', 1, 15, 200, 15, 'A', 'whatever');
[ok, why] = verify_message(mu, cfg, 15.1, L);
R = chk(R, 'unregistered ID rejected', ~ok && strcmp(why, 'unregistered'));

ms = sign_message(cfg.ambId, 50, 5, 200, 15, 'A', key);
[ok, why] = verify_message(ms, cfg, 20, L);
R = chk(R, 'stale message rejected', ~ok && strcmp(why, 'stale'));

[ok, ~] = verify_message(m1, cfg, 10.2, newMap());
R = chk(R, 'each junction keeps its own replay state', ok);

nFail = sum(~cellfun(@(r) r{2}, R));
fprintf('\n%d/%d security tests passed\n', numel(R) - nFail, numel(R));
assert(nFail == 0, 'Some security tests failed');
end

function R = chk(R, name, cond)
R{end+1} = {name, logical(cond)};
fprintf('  [%s] %s\n', ternary(cond, 'PASS', 'FAIL'), name);
end

function s = ternary(c, a, b)
if c, s = a; else, s = b; end
end
