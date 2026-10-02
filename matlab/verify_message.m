function [ok, reason] = verify_message(msg, cfg, now, lastSeq)
%VERIFY_MESSAGE  Junction-side check: registered ID, valid HMAC, fresh, not replayed.
%   lastSeq is a containers.Map (handle) holding the last accepted seq per ID for ONE junction.
ok = false;
if ~isKey(cfg.keys, msg.id)
    reason = 'unregistered'; return;
end
expected = hmac_sha256(cfg.keys(msg.id), message_payload(msg));
if ~consttime_equal(expected, msg.sig)
    reason = 'bad_signature'; return;
end
if abs(now - msg.ts) > cfg.maxMsgAge
    reason = 'stale'; return;
end
if isKey(lastSeq, msg.id) && msg.seq <= lastSeq(msg.id)
    reason = 'replay'; return;
end
lastSeq(msg.id) = msg.seq;
ok = true; reason = 'ok';
end

function eq = consttime_equal(a, b)
if numel(a) ~= numel(b), eq = false; return; end
eq = ~any(bitxor(uint8(a), uint8(b)));
end
