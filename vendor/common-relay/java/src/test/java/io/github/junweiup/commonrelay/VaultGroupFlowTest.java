package io.github.junweiup.commonrelay;

import org.json.JSONObject;
import org.junit.Test;
import org.junit.Assume;
import static org.junit.Assert.*;
import java.util.UUID;

/** Isolated loopback service only; never uses an installed app's configuration. */
public class VaultGroupFlowTest {
    private RelayGroups client(String url) throws Exception {
        return new RelayGroups(new JSONObject().put("app", "passwordvault").put("url", url)
            .put("device", UUID.randomUUID().toString()).put("secret_key", Crypto.hex(Crypto.random(32))), true);
    }
    @Test public void createApproveRenameRemoveAndDisband() throws Exception {
        String url = System.getenv("PV_GROUP_TEST_URL");
        Assume.assumeTrue(url != null && url.startsWith("ws://127.0.0.1:"));
        RelayGroups owner = client(url), phone = client(url);
        owner.prepareCreate("Java fixture", "Owner");
        String creation = owner.config.getJSONObject("pending_create").toString();
        owner.prepareCreate("Ignored retry name", "Ignored retry name");
        assertEquals(creation, owner.config.getJSONObject("pending_create").toString());
        owner.create();
        JSONObject invitation = owner.invite();
        phone.config.put("group", invitation.getString("group"));
        phone.prepareJoin(invitation, "Phone");
        String persisted = phone.config.toString();
        RelayGroups restored = new RelayGroups(new JSONObject(persisted), true);
        restored.join(invitation, "Ignored retry name");
        assertEquals(phone.config.getJSONObject("pending_join").toString(), restored.config.getJSONObject("pending_join").toString());
        JSONObject request = owner.pending(invitation);
        assertNotNull(request);
        owner.approve(invitation, request, false);
        assertTrue(restored.finishJoin());
        assertThrows(Exception.class, () -> restored.invite());
        assertThrows(Exception.class, () -> owner.prepareExit(false));
        restored.rename(restored.config.getString("device"), "Renamed phone");
        owner.refresh();
        assertEquals(2, RelayGroups.unpack(owner.config.getJSONObject("group_entry")).getJSONArray("members").length());
        owner.remove(restored.config.getString("device"));
        assertThrows(Exception.class, () -> restored.refresh());
        owner.prepareExit(true); owner.exit();
        assertTrue(RelayGroups.unpack(owner.config.getJSONObject("group_entry")).getBoolean("closed"));
    }
    @Test public void automaticCompactInvitationAndRestartKeepOrdinaryMembership() throws Exception {
        String url = System.getenv("PV_GROUP_TEST_URL");
        Assume.assumeTrue(url != null && url.startsWith("ws://127.0.0.1:"));
        RelayGroups owner = client(url), phone = client(url);
        owner.prepareCreate("Automatic fixture", "Owner"); owner.create();
        JSONObject invitation = owner.invite("auto", true);
        String link = invitation.getString("short_link");
        assertTrue(link.startsWith("common-relay:")); assertTrue(link.length() < 200);
        JSONObject resolved = phone.resolveInvitation(link);
        RelayGroups wrongApp = client(url); wrongApp.config.put("app", "other");
        assertThrows(Exception.class, () -> wrongApp.resolveInvitation(link));
        phone.config.put("group", resolved.getString("group"));
        phone.prepareJoin(resolved, "Phone"); phone.join(resolved, "Phone");
        RelayGroups restored = new RelayGroups(new JSONObject(phone.config.toString()), true);
        assertTrue(restored.finishJoin()); assertFalse(restored.config.has("pending_join"));
        owner.refresh();
        JSONObject state = RelayGroups.unpack(owner.config.getJSONObject("group_entry"));
        assertEquals(2, state.getJSONArray("members").length());
        for (int i=0; i<state.getJSONArray("members").length(); i++) {
            JSONObject member = state.getJSONArray("members").getJSONObject(i);
            if (member.getString("device").equals(restored.config.getString("device"))) assertFalse(member.getBoolean("manager"));
        }
        assertThrows(Exception.class, () -> restored.invite("auto"));
        owner.prepareExit(true); owner.exit();
    }
    @Test public void joinDraftDoesNotRequireNetworkAndProductionRejectsLoopbackHTTP() throws Exception {
        RelayGroups phone = client("ws://127.0.0.1:1/relay/v1/ws");
        JSONObject invitation = new JSONObject().put("version", 1).put("app", "passwordvault").put("group", "fixture")
            .put("url", "ws://127.0.0.1:1/relay/v1/ws").put("id", "fixture").put("secret", "fixture")
            .put("expires", System.currentTimeMillis()/1000+600).put("manager", new JSONObject());
        phone.config.put("group", "fixture"); phone.prepareJoin(invitation, "Phone");
        assertTrue(phone.config.has("pending_join"));
        assertThrows(Exception.class, () -> new RelayGroups(phone.config, false));
    }
}
