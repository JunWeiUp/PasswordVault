import Foundation

/// SecretBox authenticates the entire invitation. Fragment keys never enter HTTP; only a
/// domain-separated read token does. Sealing, opening, building and parsing are
/// implemented in vault-core (`RelayCoreProtocol`).
public enum RelayInvitationLinks {
    public static func base64url(_ bytes: Data) -> String { bytes.base64EncodedString().replacingOccurrences(of:"+",with:"-").replacingOccurrences(of:"/",with:"_").replacingOccurrences(of:"=",with:"") }
    public static func readToken(_ key: Data) throws -> String {
        try text(RelayCoreProtocol.call("read-token", ["key": key.relayHex]), "token")
    }
    public static func seal(_ invitation: [String:Any], key: Data, nonce: Data) throws -> String {
        try text(RelayCoreProtocol.call("seal-invitation", ["invitation": invitation, "key": key.relayHex, "nonce": nonce.relayHex]), "packet")
    }
    public static func open(_ packet: String, key: Data) throws -> [String:Any] {
        guard let invitation = try RelayCoreProtocol.call("open-invitation", ["packet": packet, "key": key.relayHex])["invitation"] as? [String:Any] else { throw RelayError.invalid("invitation packet scope") }
        return invitation
    }
    /// An optional server access password rides in the fragment (`#key.base64url(ASCII password)`), which never reaches HTTP.
    public static func make(_ invitation: [String:Any], key: Data, password: String? = nil) throws -> String {
        guard let url = invitation["url"] as? String else { throw RelayError.invalid("invitation URL") }
        var request: [String:Any] = ["invitation": invitation, "key": key.relayHex, "allowLocal": url.hasPrefix("ws://127.0.0.1:")]
        if let password { request["password"] = password }
        return try text(RelayCoreProtocol.call("make-link", request), "link")
    }
    public static func parse(_ link: String, allowLocalTest: Bool = false) throws -> (url: String,id: String,key: Data,password: String?) {
        let p = try RelayCoreProtocol.call("parse-link", ["link": link, "allowLocal": allowLocalTest])
        return (try text(p, "url"), try text(p, "id"), try Data(relayHex: text(p, "key")), p["password"] as? String)
    }
    private static func text(_ value: [String:Any], _ key: String) throws -> String {
        guard let result = value[key] as? String else { throw RelayError.invalid("relay protocol result") }
        return result
    }
}
