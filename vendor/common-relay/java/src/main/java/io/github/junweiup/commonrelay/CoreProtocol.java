package io.github.junweiup.commonrelay;

import org.json.JSONObject;

/**
 * Bridge to the shared Rust protocol in PasswordVault's vault-core
 * ({@code crates/vault-core/src/relay_protocol}). Group-chain verification, signing,
 * strict payload parsing, invitation links and message envelopes are implemented once
 * there; this SDK only keeps transport, file streams and the delivery journal.
 * The host app installs a backend that forwards to {@code VaultSession.command}.
 */
public final class CoreProtocol {
    private CoreProtocol() {}
    /** Executes one {@code relay-protocol-*} request and returns its JSON result. */
    public interface Backend { JSONObject call(JSONObject request) throws Exception; }
    private static volatile Backend backend;
    public static void install(Backend value) { backend = value; }
    public static boolean installed() { return backend != null; }
    static JSONObject call(String op, JSONObject request) throws Exception {
        Backend b = backend;
        if (b == null) throw new IllegalStateException("Relay protocol backend not installed");
        return b.call(request.put("op", "relay-protocol-" + op));
    }
}
