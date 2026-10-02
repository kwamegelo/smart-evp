function s = message_payload(msg)
%MESSAGE_PAYLOAD  Canonical string that is signed (src is NOT signed: evaluation metadata only).
s = sprintf('%s|%d|%.3f|%.2f|%.2f|%s', char(msg.id), msg.seq, msg.ts, msg.x, msg.v, char(msg.dir));
end
