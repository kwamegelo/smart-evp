function hex = hmac_sha256(key, message)
%HMAC_SHA256  HMAC-SHA256 as a lowercase hex string (uses MATLAB's built-in Java).
keyBytes = typecast(uint8(char(key)),     'int8');
msgBytes = typecast(uint8(char(message)), 'int8');
mac = javax.crypto.Mac.getInstance('HmacSHA256');
mac.init(javax.crypto.spec.SecretKeySpec(keyBytes, 'HmacSHA256'));
out = typecast(int8(mac.doFinal(msgBytes)), 'uint8');
hex = lower(reshape(dec2hex(out, 2).', 1, []));
end
