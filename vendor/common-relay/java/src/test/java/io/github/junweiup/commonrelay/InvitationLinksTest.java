package io.github.junweiup.commonrelay;
import org.junit.Test;
import static org.junit.Assert.*;
import org.json.JSONObject;
import java.nio.file.Files;
import java.nio.file.Path;
public class InvitationLinksTest {
 @Test public void sharedPacketAndTampering()throws Exception{
  JSONObject v=new JSONObject(new String(Files.readAllBytes(Path.of("../protocol/invitation-link-vectors.json")),java.nio.charset.StandardCharsets.UTF_8));byte[] key=Crypto.unhex(v.getString("key"));JSONObject inv=InvitationLinks.open(v.getString("packet"),key);
  assertEquals(v.getJSONObject("invitation").getString("id"),inv.getString("id"));assertEquals(v.getString("read_token"),InvitationLinks.readToken(key));assertEquals(v.getString("link"),InvitationLinks.make(inv,key));assertEquals(inv.getString("url"),InvitationLinks.parse(v.getString("link"),false).url);
  assertEquals(inv.getString("id"),InvitationLinks.open(InvitationLinks.seal(inv,key,Crypto.unhex(v.getString("nonce"))),key).getString("id"));
  assertThrows(Exception.class,()->InvitationLinks.open(v.getString("packet"),new byte[32]));
  assertThrows(Exception.class,()->InvitationLinks.parse(v.getString("link")+"=",false));
  assertThrows(Exception.class,()->InvitationLinks.parse(v.getString("link").replace("eglish.top","user@eglish.top"),false));
 }
}
