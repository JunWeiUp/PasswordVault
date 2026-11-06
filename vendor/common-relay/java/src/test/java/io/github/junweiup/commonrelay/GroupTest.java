package io.github.junweiup.commonrelay;
import org.junit.Test;
import static org.junit.Assert.*;
import org.json.JSONObject;
import java.nio.file.Files;
import java.nio.file.Path;
public class GroupTest {
 @Test public void sharedMembershipVectors() throws Exception {
  JSONObject v=new JSONObject(new String(Files.readAllBytes(java.nio.file.Paths.get("../protocol/group-vectors.json")),java.nio.charset.StandardCharsets.UTF_8));
  RelayGroups g=new RelayGroups(v.getJSONObject("config"),false);
  assertEquals(v.getJSONObject("manager").getString("signing_key"),g.member("Mac").getString("signing_key"));
  JSONObject a=v.getJSONObject("initial"),b=v.getJSONObject("approved"),c=v.getJSONObject("removed");
  RelayGroups.verify(v.getJSONObject("self_service"),v.getJSONObject("manager").getString("signing_key"));
  RelayGroups.verify(a,v.getJSONObject("manager").getString("signing_key"));g.advance(a,b);g.advance(b,c);
  g.advance(b,v.getJSONObject("renamed"));assertThrows(Exception.class,()->g.advance(b,v.getJSONObject("unauthorized_rename")));
  g.advance(b,v.getJSONObject("left"));g.advance(b,v.getJSONObject("disbanded"));assertThrows(Exception.class,()->g.advance(b,v.getJSONObject("unauthorized_disband")));
  assertThrows(Exception.class,()->g.advance(a,c));
  JSONObject auto=v.getJSONObject("auto_admission");g.advance(a,auto.getJSONObject("approved"));
  for(int i=0;i<auto.getJSONArray("invalid").length();i++){JSONObject item=auto.getJSONArray("invalid").getJSONObject(i);assertThrows(item.getString("case"),Exception.class,()->g.advance(a,item.getJSONObject("entry")));}
  JSONObject strict=v.getJSONObject("strict_payload");
  for(int i=0;i<strict.getJSONArray("valid").length();i++)g.advance(b,strict.getJSONArray("valid").getJSONObject(i).getJSONObject("entry"));
  for(String set:new String[]{"invalid","invalid_auto"})for(int i=0;i<strict.getJSONArray(set).length();i++){JSONObject item=strict.getJSONArray(set).getJSONObject(i);JSONObject base=set.equals("invalid")?b:a;assertThrows(item.getString("case"),Exception.class,()->g.advance(base,item.getJSONObject("entry")));}
  JSONObject bad=new JSONObject(b.toString()).put("signature","00".repeat(64));assertThrows(Exception.class,()->g.advance(a,bad));
 }
}
