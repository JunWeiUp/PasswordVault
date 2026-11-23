package io.github.junweiup.commonrelay;

import com.sun.jna.Library;
import com.sun.jna.Native;
import com.sun.jna.Memory;
import com.sun.jna.Pointer;
import com.sun.jna.ptr.LongByReference;
import org.json.JSONArray;
import org.json.JSONObject;
import java.nio.charset.StandardCharsets;
import java.util.Arrays;

import java.util.Map;
import java.security.SecureRandom;

/** Keys supplied to this class must have been verified through a trusted pairing channel. */
public final class Crypto {
    interface Sodium extends Library {
        int sodium_init();
        com.sun.jna.NativeLong crypto_secretstream_xchacha20poly1305_statebytes();
        int crypto_secretstream_xchacha20poly1305_init_push(Pointer state, byte[] header, byte[] key);
        int crypto_secretstream_xchacha20poly1305_init_pull(Pointer state, byte[] header, byte[] key);
        int crypto_secretstream_xchacha20poly1305_push(Pointer state, byte[] out, LongByReference len, byte[] plain, long plainLen, byte[] aad, long aadLen, byte tag);
        int crypto_secretstream_xchacha20poly1305_pull(Pointer state, byte[] out, LongByReference len, byte[] tag, byte[] cipher, long cipherLen, byte[] aad, long aadLen);
    }
    /** libsodium is loaded only when a file stream is used, so hex/random/journal helpers work without it. */
    static final class Lib {
        static final Sodium S = Native.load("sodium",Sodium.class);
        static { if(S.sodium_init()<0) throw new IllegalStateException("Sodium initialization failed"); }
    }
    public final String app, group, device;
    private final byte[] secret;
    private final Map<String,String> trusted;
    public Crypto(String app,String group,String device,String secret,Map<String,String> trusted) {
        this.app=app;this.group=group;this.device=device;this.secret=unhex(secret);this.trusted=java.util.Collections.unmodifiableMap(new java.util.HashMap<>(trusted));
        if(this.secret.length!=32) throw new IllegalArgumentException("Invalid secret key");
    }
    public static byte[] random(int count) { byte[] b=new byte[count];new SecureRandom().nextBytes(b);return b; }
    public static String hex(byte[] bytes) { StringBuilder s=new StringBuilder();for(byte b:bytes)s.append(String.format("%02x",b&255));return s.toString(); }
    public static byte[] unhex(String value) { if(value.length()%2!=0)throw new IllegalArgumentException("Invalid hex");byte[] b=new byte[value.length()/2];for(int i=0;i<b.length;i++)b[i]=(byte)Integer.parseInt(value.substring(i*2,i*2+2),16);return b; }
    private volatile String publicKey;
    /** Envelope public key, derived in vault-core. */
    public String publicKey()throws Exception{String k=publicKey;if(k==null)publicKey=k=CoreProtocol.call("keys",new JSONObject().put("secret",hex(secret))).getString("publicKey");return k;}
    private String peer(String name){String key=trusted.get(name);if(key==null)throw new IllegalArgumentException("Untrusted peer");if(key.length()!=64)throw new IllegalArgumentException("Invalid peer key");return key;}
    private JSONArray context(String from,String to,String kind,String id) { return new JSONArray().put(1).put(app).put(group).put(from).put(to).put(kind).put(id); }
    public byte[] aad(String from,String to,String kind,String id,long sequence) { return context(from,to,kind,id).put(sequence).toString().getBytes(StandardCharsets.UTF_8); }
    /** Envelope sealing/opening (context binding included) is implemented in vault-core. */
    private JSONObject envelope(String peer)throws Exception{return new JSONObject().put("app",app).put("group",group).put("device",device).put("secret",hex(secret)).put("peerKey",peer(peer));}
    public String seal(String to,String kind,String id,JSONObject value) throws Exception {
        return CoreProtocol.call("envelope-seal",envelope(to).put("to",to).put("kind",kind).put("id",id).put("value",value)).getString("body");
    }
    public JSONObject open(String from,String kind,String id,String envelope) throws Exception {
        return CoreProtocol.call("envelope-open",envelope(from).put("from",from).put("kind",kind).put("id",id).put("body",envelope)).getJSONObject("value");
    }
    static void check(int result){if(result!=0)throw new IllegalArgumentException("Cryptographic verification failed");}
    public static final class SecretStream implements AutoCloseable {
        private final Memory state=new Memory(Lib.S.crypto_secretstream_xchacha20poly1305_statebytes().longValue());
        private final byte[] key,header;
        public volatile boolean finished=false; private boolean closed=false;
        private final boolean writer;
        public SecretStream(){writer=true;key=random(32);header=new byte[24];check(Lib.S.crypto_secretstream_xchacha20poly1305_init_push(state,header,key));}
        public SecretStream(JSONObject descriptor)throws Exception{writer=false;key=unhex(descriptor.getString("key"));header=unhex(descriptor.getString("header"));if(key.length!=32||header.length!=24)throw new IllegalArgumentException("Invalid descriptor");check(Lib.S.crypto_secretstream_xchacha20poly1305_init_pull(state,header,key));}
        public JSONObject descriptor()throws Exception{return new JSONObject().put("key",hex(key)).put("header",hex(header));}
        public synchronized byte[] push(byte[] plain,byte[] aad,boolean last){if(closed||!writer||finished||plain.length>65519)throw new IllegalStateException("Invalid stream state");byte[] out=new byte[plain.length+17];check(Lib.S.crypto_secretstream_xchacha20poly1305_push(state,out,new LongByReference(),plain,plain.length,aad,aad.length,(byte)(last?3:0)));finished=last;return out;}
        public synchronized byte[] pull(byte[] cipher,byte[] aad){if(closed||writer||finished||cipher.length<17||cipher.length>65536)throw new IllegalStateException("Invalid stream state");byte[] out=new byte[cipher.length-17],tag=new byte[1];check(Lib.S.crypto_secretstream_xchacha20poly1305_pull(state,out,new LongByReference(),tag,cipher,cipher.length,aad,aad.length));if(tag[0]!=0&&tag[0]!=3)throw new IllegalArgumentException("Unexpected tag");finished=tag[0]==3;return out;}
        public synchronized void close(){if(closed)return;closed=true;state.clear();state.close();Arrays.fill(key,(byte)0);}
    }
}
