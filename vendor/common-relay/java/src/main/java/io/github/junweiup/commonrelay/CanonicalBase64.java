package io.github.junweiup.commonrelay;

import java.util.Base64;

/** Canonical padded encoding shared by signed payloads and encrypted packets. */
final class CanonicalBase64 {
    private CanonicalBase64() {}
    static byte[] decode(String value) {
        if (value.length() % 4 != 0 || !value.matches("[A-Za-z0-9+/]*={0,2}"))
            throw new IllegalArgumentException("Non-canonical base64");
        byte[] decoded = Base64.getDecoder().decode(value);
        if (!Base64.getEncoder().encodeToString(decoded).equals(value))
            throw new IllegalArgumentException("Non-canonical base64");
        return decoded;
    }
}
