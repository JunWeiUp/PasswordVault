package io.github.junweiup.commonrelay;

import java.util.Base64;
import org.json.JSONObject;

/**
 * The URL fragment key never goes to HTTP; only a domain-separated read token does.
 * Sealing, opening, building and parsing are implemented in vault-core ({@link CoreProtocol}).
 */
public final class InvitationLinks {
    private InvitationLinks() {}
    public static String base64url(byte[] b){return Base64.getUrlEncoder().withoutPadding().encodeToString(b);}
    public static String readToken(byte[] key)throws Exception{
        return CoreProtocol.call("read-token",new JSONObject().put("key",Crypto.hex(key))).getString("token");
    }
    public static String seal(JSONObject invitation,byte[] key,byte[] nonce)throws Exception{
        return CoreProtocol.call("seal-invitation",new JSONObject().put("invitation",invitation).put("key",Crypto.hex(key)).put("nonce",Crypto.hex(nonce))).getString("packet");
    }
    public static JSONObject open(String packet,byte[] key)throws Exception{
        return CoreProtocol.call("open-invitation",new JSONObject().put("packet",packet).put("key",Crypto.hex(key))).getJSONObject("invitation");
    }
    public static String make(JSONObject invitation,byte[] key)throws Exception{return make(invitation,key,null);}
    /** @param password optional server access password, appended to the fragment (never sent over HTTP) as ".base64url(ASCII)". */
    public static String make(JSONObject invitation,byte[] key,String password)throws Exception{
        JSONObject request=new JSONObject().put("invitation",invitation).put("key",Crypto.hex(key)).put("allowLocal",invitation.getString("url").startsWith("ws://127.0.0.1:"));
        if(password!=null)request.put("password",password);
        return CoreProtocol.call("make-link",request).getString("link");
    }
    public static final class Parsed {
        public final String url,id;public final byte[] key;
        /** Server access password carried by the link, or null. */
        public final String password;
        Parsed(String url,String id,byte[] key,String password){this.url=url;this.id=id;this.key=key;this.password=password;}
    }
    public static Parsed parse(String text,boolean allowLocalTest)throws Exception{
        JSONObject p=CoreProtocol.call("parse-link",new JSONObject().put("link",text).put("allowLocal",allowLocalTest));
        return new Parsed(p.getString("url"),p.getString("id"),Crypto.unhex(p.getString("key")),p.isNull("password")?null:p.getString("password"));
    }
}
