package io.github.junweiup.commonrelay;
import org.junit.Test;
import static org.junit.Assert.*;
import org.json.JSONObject;
import java.nio.file.*;
import java.nio.charset.StandardCharsets;
import java.util.Map;
public class CryptoTest {
    @Test public void pythonVectors()throws Exception {
        JSONObject v=new JSONObject(new String(Files.readAllBytes(Path.of("../protocol/crypto-vectors.json")),StandardCharsets.UTF_8));
        Crypto bob=new Crypto("example","test","bob",v.getString("bob_secret"),Map.of("alice",v.getString("alice_public")));
        assertEquals(v.getString("bob_public"),bob.publicKey());String id=v.getString("id");
        assertEquals("aGVsbG8=",bob.open("alice","message",id,v.getString("message")).getString("data"));
        assertThrows(Exception.class,()->bob.open("alice","message","wrong",v.getString("message")));
        assertEquals(v.getLong("offline_expires"),bob.open("alice","message",id,v.getString("offline_message")).getLong("expires"));
        try(Crypto.SecretStream stream=new Crypto.SecretStream(v.getJSONObject("stream_descriptor"))){byte[] aad=bob.aad("alice","bob","stream",id,0);assertEquals(v.getString("stream_aad"),new String(aad,StandardCharsets.UTF_8));assertArrayEquals("hello".getBytes(StandardCharsets.UTF_8),stream.pull(Crypto.unhex(v.getString("stream_ciphertext")),aad));assertTrue(stream.finished);}
    }
    @Test public void closedStreamsRejectUseAndAllowRepeatedClose()throws Exception {
        Crypto.SecretStream writer=new Crypto.SecretStream();
        Crypto.SecretStream reader=new Crypto.SecretStream(writer.descriptor());
        byte[] cipher=writer.push(new byte[]{1},new byte[0],false);
        writer.close();writer.close();reader.close();reader.close();
        assertThrows(IllegalStateException.class,()->writer.push(new byte[]{1},new byte[0],false));
        assertThrows(IllegalStateException.class,()->reader.pull(cipher,new byte[0]));
    }
}
