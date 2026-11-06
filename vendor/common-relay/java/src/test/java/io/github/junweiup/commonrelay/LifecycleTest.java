package io.github.junweiup.commonrelay;

import org.junit.Test;
import org.json.JSONObject;
import okhttp3.OkHttpClient;
import java.lang.reflect.*;
import java.util.Collections;
import java.util.concurrent.*;
import static org.junit.Assert.*;

public class LifecycleTest {
    @Test public void forwardsGroupChangeWithoutTrustingItsContents() throws Exception {
        final JSONObject[] received = new JSONObject[1];
        Crypto crypto = new Crypto("example", "test", "alice", "01".repeat(32), Collections.emptyMap());
        try (RelayClient client = new RelayClient(new OkHttpClient(), crypto, new RelayClient.Listener() {
            public void onReady() {}
            public void onClosed(Throwable error) {}
            public void onEvent(JSONObject event) { received[0] = event; }
        })) {
            Method dispatch = RelayClient.class.getDeclaredMethod("dispatch", JSONObject.class);
            dispatch.setAccessible(true);
            dispatch.invoke(client, new JSONObject().put("type", "group.changed").put("revision", 2));
            assertNotNull("Applications must be notified to verify the signed chain", received[0]);
            assertEquals(2, received[0].getInt("revision"));
        }
    }
    @Test public void repeatedReceiveAfterCloseNeverBlocks() throws Exception {
        Crypto crypto = new Crypto("example", "test", "alice", "01".repeat(32), Collections.emptyMap());
        RelayClient client = new RelayClient(new OkHttpClient(), crypto, new RelayClient.Listener() {
            public void onReady() {} public void onClosed(Throwable e) {} public void onEvent(JSONObject e) {}
        });
        Constructor<RelayClient.Stream> constructor = RelayClient.Stream.class.getDeclaredConstructor(RelayClient.class, String.class, String.class, Crypto.SecretStream.class);
        constructor.setAccessible(true);
        RelayClient.Stream stream = constructor.newInstance(client, "peer", "01".repeat(16), new Crypto.SecretStream());
        ExecutorService executor = Executors.newSingleThreadExecutor();
        try {
            stream.close(); stream.close();
            for (int i = 0; i < 2; i++) executor.submit(() -> assertThrows(Exception.class, stream::receive)).get(1, TimeUnit.SECONDS);
            assertThrows(Exception.class, () -> stream.send(new byte[0], false));
        } finally { executor.shutdownNow(); client.close(); }
    }
}
