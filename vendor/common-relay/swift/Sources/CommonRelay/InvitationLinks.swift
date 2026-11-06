import Foundation
import Clibsodium

/// SecretBox authenticates the entire invitation. Fragment keys never enter HTTP.
public enum RelayInvitationLinks {
    public static func base64url(_ bytes: Data) -> String { bytes.base64EncodedString().replacingOccurrences(of:"+",with:"-").replacingOccurrences(of:"/",with:"_").replacingOccurrences(of:"=",with:"") }
    private static func decode(_ text: String, size: Int) throws -> Data {
        guard !text.isEmpty, text.allSatisfy({"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_".contains($0)}) else { throw RelayError.invalid("compact invitation encoding") }
        let padded=text.replacingOccurrences(of:"-",with:"+").replacingOccurrences(of:"_",with:"/")+String(repeating:"=",count:(4-text.count%4)%4)
        guard let raw=Data(base64Encoded:padded),raw.count==size,base64url(raw)==text else { throw RelayError.invalid("compact invitation size") };return raw
    }
    public static func readToken(_ key: Data) throws -> String {
        guard key.count==32 else { throw RelayError.invalid("invitation key size") }
        return RelayGroups.digest(Data("common-relay/invitation-link/read/v1\0".utf8)+key)
    }
    public static func seal(_ invitation: [String:Any], key: Data, nonce: Data) throws -> String {
        guard key.count==32,nonce.count==24 else { throw RelayError.invalid("invitation key/nonce size") }
        let plain=try json(["version":1,"purpose":"common-relay/invitation-link/v1","invitation":invitation]);var cipher=[UInt8](repeating:0,count:plain.count+16)
        try checked(crypto_secretbox_easy(&cipher,Array(plain),UInt64(plain.count),Array(nonce),Array(key)))
        return (nonce+Data(cipher)).base64EncodedString()
    }
    public static func open(_ packet: String, key: Data) throws -> [String:Any] {
        guard key.count==32,let raw=Data(base64Encoded:packet),(40...16384).contains(raw.count) else { throw RelayError.invalid("invitation packet size") }
        let nonce=raw.prefix(24),cipher=raw.dropFirst(24);var plain=[UInt8](repeating:0,count:cipher.count-16)
        try checked(crypto_secretbox_open_easy(&plain,Array(cipher),UInt64(cipher.count),Array(nonce),Array(key)))
        let value=try dictionary(Data(plain));guard value["version"] as? Int == 1,value["purpose"] as? String == "common-relay/invitation-link/v1",let invitation=value["invitation"] as? [String:Any] else { throw RelayError.invalid("invitation packet scope") };return invitation
    }
    /// An optional server access password rides in the fragment (`#key.base64url(ASCII password)`), which never reaches HTTP.
    public static func make(_ invitation: [String:Any], key: Data, password: String? = nil) throws -> String {
        guard let url=invitation["url"] as? String,var u=URLComponents(string:url),let id=invitation["id"] as? String else { throw RelayError.invalid("invitation URL") }
        try RelayAccess.validate(password)
        u.scheme="common-relay";u.path="/i/"+base64url(try Data(relayHex:id));u.fragment=base64url(key)+(password.map { "."+base64url(Data($0.utf8)) } ?? "")
        guard let link=u.string else { throw RelayError.invalid("invitation URL") };return link
    }
    private static func fragmentPassword(_ text: String) throws -> String {
        guard !text.isEmpty, text.allSatisfy({"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_".contains($0)}) else { throw RelayError.invalid("compact invitation encoding") }
        let padded=text.replacingOccurrences(of:"-",with:"+").replacingOccurrences(of:"_",with:"/")+String(repeating:"=",count:(4-text.count%4)%4)
        guard let raw=Data(base64Encoded:padded),base64url(raw)==text,let password=String(data:raw,encoding:.ascii) else { throw RelayError.invalid("compact invitation encoding") }
        try RelayAccess.validate(password);return password
    }
    public static func parse(_ text: String, allowLocalTest: Bool = false) throws -> (url: String,id: String,key: Data,password: String?) {
        guard text.count<=2048,var u=URLComponents(string:text),u.scheme=="common-relay",let host=u.host,!host.isEmpty,u.user==nil,u.password==nil,u.query==nil,u.percentEncodedPath.hasPrefix("/i/"),let fragment=u.percentEncodedFragment else { throw RelayError.invalid("compact invitation URL") }
        let parts=fragment.split(separator:".",maxSplits:1,omittingEmptySubsequences:false).map(String.init)
        let id=try decode(String(u.percentEncodedPath.dropFirst(3)),size:16),key=try decode(parts[0],size:32)
        let password=parts.count==2 ? try fragmentPassword(parts[1]) : nil // gitleaks:allow -- synthetic fixture or non-secret expression
        u.scheme=allowLocalTest && host=="127.0.0.1" ? "ws":"wss";u.path="/relay/v1/ws";u.fragment=nil
        guard let url=u.string else { throw RelayError.invalid("invitation URL") };return (url,id.relayHex,key,password)
    }
}
