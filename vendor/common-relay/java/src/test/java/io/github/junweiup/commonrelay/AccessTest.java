package io.github.junweiup.commonrelay;

import okhttp3.*;
import org.json.JSONObject;
import org.junit.Test;
import java.io.File;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.*;
import java.util.concurrent.*;
import static org.junit.Assert.*;

public class AccessTest {
    private static final String PASSWORD="correct-horse-1";
    /** Records every request and answers 401 without touching the network. */
    private static OkHttpClient recording(List<Request> seen){
        return new OkHttpClient.Builder().addInterceptor(chain->{Request r=chain.request();synchronized(seen){seen.add(r);seen.notifyAll();}return new Response.Builder().request(r).protocol(Protocol.HTTP_1_1).code(401).message("Unauthorized").body(ResponseBody.create("unauthorized",MediaType.get("text/plain"))).build();}).build();
    }
    @Test public void validatesPassword(){
        assertNull(RelayAccess.validate(null));
        assertEquals(PASSWORD,RelayAccess.validate(PASSWORD));
        for(String bad:new String[]{"short","has space1","tab\tpassword","x".repeat(129),"密码密码密码密码"}){
            IllegalArgumentException e=assertThrows(IllegalArgumentException.class,()->RelayAccess.validate(bad));
            assertFalse("message must not echo the password",e.getMessage().contains(bad));
        }
        assertThrows(IllegalArgumentException.class,()->new RelayFiles(new OkHttpClient(),"https://relay.example.com/relay/v1/files","t","short"));
        assertThrows(IllegalArgumentException.class,()->new RelayGroups(new JSONObject().put("url","wss://relay.example.com/relay/v1/ws").put("password","short"),false));
    }
    @Test public void webSocketUpgradeSendsPassword()throws Exception{
        List<Request> seen=new ArrayList<>();CountDownLatch closed=new CountDownLatch(1);
        Crypto crypto=new Crypto("example","test","alice","01".repeat(32),Collections.emptyMap());
        try(RelayClient client=new RelayClient(recording(seen),crypto,new RelayClient.Listener(){public void onReady(){}public void onEvent(JSONObject e){}public void onClosed(Throwable e){closed.countDown();}})){
            assertThrows(IllegalArgumentException.class,()->client.connect("wss://relay.example.com/relay/v1/ws","0".repeat(64),"bad pass"));
            client.connect("wss://relay.example.com/relay/v1/ws","0".repeat(64),PASSWORD);
            assertTrue(closed.await(5,TimeUnit.SECONDS));
        }
        assertEquals(1,seen.size());assertEquals(PASSWORD,seen.get(0).header(RelayAccess.HEADER));
        List<Request> plain=new ArrayList<>();CountDownLatch done=new CountDownLatch(1);
        try(RelayClient client=new RelayClient(recording(plain),crypto,new RelayClient.Listener(){public void onReady(){}public void onEvent(JSONObject e){}public void onClosed(Throwable e){done.countDown();}})){
            client.connect("wss://relay.example.com/relay/v1/ws","0".repeat(64));assertTrue(done.await(5,TimeUnit.SECONDS));
        }
        assertNull(plain.get(0).header(RelayAccess.HEADER));
    }
    @Test public void groupAndInvitationLinkRequestsSendPassword()throws Exception{
        List<Request> seen=new ArrayList<>();
        JSONObject config=new JSONObject().put("url","wss://relay.example.com/relay/v1/ws").put("app","example").put("group","test").put("device","alice").put("secret_key","01".repeat(32)).put("token","0".repeat(64)).put("password",PASSWORD);
        RelayGroups groups=new RelayGroups(config,false,recording(seen));
        assertThrows(Exception.class,()->groups.call("GET","/group?after=0",null,null));
        assertThrows(Exception.class,()->groups.call("POST","/group/create",new JSONObject(),null));
        JSONObject v=new JSONObject(new String(Files.readAllBytes(Path.of("../protocol/invitation-link-vectors.json")),java.nio.charset.StandardCharsets.UTF_8));
        Exception e=assertThrows(Exception.class,()->groups.resolveInvitation(v.getString("link")));
        assertFalse(String.valueOf(e.getMessage()).contains(PASSWORD));
        assertEquals(3,seen.size());
        for(Request r:seen)assertEquals(PASSWORD,r.header(RelayAccess.HEADER));
        assertTrue(seen.get(2).url().encodedPath().endsWith("/link"));
        assertTrue(seen.get(2).header("Authorization").startsWith("InvitationLink "));
        List<Request> foreign=new ArrayList<>();
        RelayGroups other=new RelayGroups(new JSONObject(config.toString()).put("url","wss://other.example.com/relay/v1/ws"),false,recording(foreign));
        assertThrows(Exception.class,()->other.resolveInvitation(v.getString("link")));
        assertEquals(1,foreign.size());assertEquals("relay.example.com",foreign.get(0).url().host());
        assertNull("password must not be sent to a different relay",foreign.get(0).header(RelayAccess.HEADER));
        List<Request> carried=new ArrayList<>();
        RelayGroups scanner=new RelayGroups(new JSONObject(config.toString()).put("url","wss://other.example.com/relay/v1/ws"),false,recording(carried));
        assertThrows(Exception.class,()->scanner.resolveInvitation(v.getString("link_with_password")));
        assertEquals("link password wins",v.getString("access_password"),carried.get(0).header(RelayAccess.HEADER));
    }
    @Test public void joinAdoptsInvitationPassword()throws Exception{
        List<Request> seen=new ArrayList<>();
        JSONObject config=new JSONObject().put("url","wss://relay.example.com/relay/v1/ws").put("app","example").put("group","test").put("device","bob").put("secret_key","02".repeat(32));
        RelayGroups groups=new RelayGroups(config,false,recording(seen));
        JSONObject inv=new JSONObject().put("version",1).put("mode","manual").put("url",config.getString("url")).put("app","example").put("group","test").put("id","ab".repeat(16)).put("expires",System.currentTimeMillis()/1000+600).put("secret","cd".repeat(32)).put("password","bad pass");
        assertThrows(IllegalArgumentException.class,()->groups.join(inv,"Bob"));
        assertTrue(seen.isEmpty());
        inv.put("password",PASSWORD);
        assertThrows(Exception.class,()->groups.join(inv,"Bob"));
        assertEquals(PASSWORD,config.getString("password"));
        assertEquals(1,seen.size());assertEquals(PASSWORD,seen.get(0).header(RelayAccess.HEADER));
    }
    @Test public void fileRequestsSendPassword()throws Exception{
        List<Request> seen=new ArrayList<>();
        RelayFiles files=new RelayFiles(recording(seen),"https://relay.example.com/relay/v1/files","0".repeat(64),PASSWORD);
        assertThrows(Exception.class,files::inbox);
        assertThrows(Exception.class,()->files.acknowledge("01".repeat(16)));
        assertEquals(2,seen.size());
        for(Request r:seen)assertEquals(PASSWORD,r.header(RelayAccess.HEADER));
    }
}
