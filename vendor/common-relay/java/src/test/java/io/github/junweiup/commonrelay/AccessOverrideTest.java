package io.github.junweiup.commonrelay;

import okhttp3.*;
import org.json.JSONObject;
import org.junit.Test;
import java.util.*;
import static org.junit.Assert.*;

/** Consumer extension: explicit edits must win, including rejecting a cleared field before HTTP. */
public class AccessOverrideTest {
    @Test public void editedPasswordWinsAndEmptyNeverFallsBack() throws Exception {
        List<Request> requests=new ArrayList<>();
        OkHttpClient http=new OkHttpClient.Builder().addInterceptor(chain->{
            requests.add(chain.request());
            return new Response.Builder().request(chain.request()).protocol(Protocol.HTTP_1_1)
                .code(401).message("Unauthorized").body(ResponseBody.create("denied",MediaType.get("text/plain"))).build();
        }).build();
        JSONObject invitation=new JSONObject().put("url","wss://relay.example.test/relay/v1/ws").put("id","01".repeat(16));
        String link=InvitationLinks.make(invitation,new byte[32],"old-pass-123");
        RelayGroups groups=new RelayGroups(new JSONObject().put("url","wss://other.example.test/relay/v1/ws").put("app","passwordvault"),false,http);
        assertThrows(Exception.class,()->groups.resolveInvitation(link,"edited-pass-456"));
        assertEquals("edited-pass-456",requests.get(0).header(RelayAccess.HEADER));
        assertEquals("relay.example.test",requests.get(0).url().host());
        assertNull(requests.get(0).url().fragment());
        assertThrows(IllegalArgumentException.class,()->groups.resolveInvitation(link,""));
        assertThrows(IllegalArgumentException.class,()->groups.resolveInvitation(link,(String)null));
        assertEquals(1,requests.size());
        assertThrows(Exception.class,()->groups.resolveInvitation(link,"edited-pass-456"));
        assertEquals("edited-pass-456",requests.get(1).header(RelayAccess.HEADER));
        assertThrows(Exception.class,()->groups.resolveInvitation(InvitationLinks.make(invitation,new byte[32]),"manual-pass-789"));
        assertEquals("manual-pass-789",requests.get(2).header(RelayAccess.HEADER));
    }

    @Test public void savedJoinKeepsIdentityAndRequestWhenPasswordChanges() throws Exception {
        JSONObject config=new JSONObject().put("url","wss://relay.example.test/relay/v1/ws")
            .put("app","passwordvault").put("group","fixture").put("device","phone").put("secret_key","02".repeat(32));
        JSONObject invitation=new JSONObject().put("version",1).put("mode","manual").put("url",config.getString("url"))
            .put("app","passwordvault").put("group","fixture").put("id","01".repeat(16))
            .put("expires",System.currentTimeMillis()/1000+600).put("secret","03".repeat(32)).put("password","first-pass-123");
        RelayGroups groups=new RelayGroups(config,false);
        groups.prepareJoin(invitation,"Phone");
        String request=config.getJSONObject("pending_join").getJSONObject("request").toString();
        String token=config.getString("token"), secret=config.getString("secret_key");
        JSONObject restored=new JSONObject(config.toString());
        invitation.put("password","corrected-pass-456"); // gitleaks:allow -- synthetic fixture or non-secret expression
        new RelayGroups(restored,false).prepareJoin(invitation,"Ignored retry name");
        assertEquals(request,restored.getJSONObject("pending_join").getJSONObject("request").toString());
        assertEquals(token,restored.getString("token"));
        assertEquals(secret,restored.getString("secret_key"));
        assertEquals("corrected-pass-456",restored.getString("password"));
    }
}
