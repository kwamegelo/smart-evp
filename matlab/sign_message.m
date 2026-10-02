function msg = sign_message(id, seq, ts, x, v, dirStr, key)
%SIGN_MESSAGE  Build a signed preemption request.
%   id: vehicle ID, seq: increasing counter, ts: timestamp [s], x: position [m],
%   v: speed [m/s], dirStr: approach road ('A'), key: shared secret.
msg.id  = id;
msg.seq = seq;
msg.ts  = ts;
msg.x   = x;
msg.v   = v;
msg.dir = dirStr;
msg.src = 'ambulance';
msg.sig = hmac_sha256(key, message_payload(msg));
end
