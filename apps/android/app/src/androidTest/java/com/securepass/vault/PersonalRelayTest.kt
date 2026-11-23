package com.securepass.vault

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.securepass.vault.core.VaultSession
import java.io.File
import java.util.UUID
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.delay
import kotlinx.coroutines.withTimeout
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class PersonalRelayTest {
    @Test fun pendingRecordsSurviveUnavailableManualSync() = runBlocking {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val directory = File(context.cacheDir, "sync-progress-${UUID.randomUUID()}")
        val vault = VaultRepository(context, directory)
        suspend fun loaded() = withTimeout(15_000) { while (vault.relay.state.value.device.isEmpty() || vault.relay.state.value.busy) delay(25) }
        try {
            withTimeout(15_000) { while (!vault.state.value.ready) delay(25) }
            vault.authenticate("fixture", true); loaded()
            val config = JSONObject(vault.command(CoreRequest.relayCredentialsRead()).getString("data"))
            assertTrue(vault.save(VaultRepository.blank("secureNote").put("title", "Offline synthetic note")))
            vault.command(CoreRequest.relayInit("mobile", "fixture-group", config.getString("device"), "fixture-hub"))
            vault.command(CoreRequest.relayTrust("fixture-hub"))
            val pending = vault.command(CoreRequest.relayStatus()).getInt("pending")
            // One note plus the category-set record; these are not two unsaved edits.
            assertEquals(2, pending)
            // Without a personal device group nothing syncs: manual sync reports BLOCKED and the
            // pending records stay intact, even with legacy pinned peers in the credentials.
            val peerKey = RelayCore.publicKey("01".repeat(32))
            config.put("group", "fixture-group").put("hub", "fixture-hub").put("paused", false)
                .put("peers", JSONObject().put("fixture-hub", peerKey)).put("token", "q".repeat(48))
                .put("endpoint", "wss://127.0.0.1:1/v2/ws")
            vault.command(CoreRequest.relayCredentialsWrite(config.toString()))
            vault.relay.setUnlocked(false); vault.relay.setUnlocked(true); loaded()
            vault.relay.syncNow()
            assertEquals(RelaySyncPhase.BLOCKED, vault.relay.state.value.sync.phase)
            assertNull(vault.relay.state.value.sync.lastSentAt)
            assertEquals(pending, vault.command(CoreRequest.relayStatus()).getInt("pending"))
            vault.relay.setUnlocked(false)
            assertFalse(vault.relay.state.value.sync.running)
            assertNull(vault.relay.state.value.sync.lastSentAt)
        } finally { vault.close(); directory.deleteRecursively() }
    }
    @Test fun serverPasswordUpgradePersistsEncryptedWithoutReplacingIdentity() = runBlocking {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val directory = File(context.cacheDir, "relay-upgrade-fixture-${UUID.randomUUID()}")
        val vault = VaultRepository(context, directory)
        val access = "relay-fixture-pass-456" // gitleaks:allow -- synthetic fixture or non-secret expression
        try {
            withTimeout(20_000) { while (!vault.state.value.ready) delay(100) }
            vault.authenticate("fixture", true)
            withTimeout(20_000) { while (vault.relay.state.value.device.isEmpty() || vault.relay.state.value.busy) delay(100) }
            val before = JSONObject(vault.command(CoreRequest.relayCredentialsRead()).getString("data"))
            vault.relay.updateServerPassword(access)
            withTimeout(20_000) {
                while (JSONObject(vault.command(CoreRequest.relayCredentialsRead()).getString("data")).optString("password") != access) delay(100)
            }
            vault.relay.setUnlocked(false)
            vault.relay.setUnlocked(true)
            withTimeout(20_000) { while (vault.relay.state.value.device.isEmpty() || vault.relay.state.value.busy) delay(100) }
            val after = JSONObject(vault.command(CoreRequest.relayCredentialsRead()).getString("data"))
            assertEquals(before.getString("device"), after.getString("device"))
            assertEquals(before.getString("secret"), after.getString("secret"))
            assertEquals(access, after.getString("password"))
            assertTrue("Encrypted relay credentials must persist inside the vault directory", File(directory, "vault/relay-private/credentials.v1.enc").exists())
            directory.walkTopDown().filter { it.isFile }.forEach { file ->
                assertFalse("Server password must not appear in plaintext on disk", file.readBytes().toString(Charsets.ISO_8859_1).contains(access))
            }
        } finally { vault.close(); directory.deleteRecursively() }
    }
    @Test fun legacyPendingEditsMigrateToSymmetricSyncWithoutConfirmation() = runBlocking {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val directory = File(context.cacheDir, "mesh-fixture-${UUID.randomUUID()}")
        val phone = VaultRepository(context, File(directory, "phone"))
        val mac = VaultSession(File(directory, "mac").absolutePath)
        fun macCall(value: JSONObject) = JSONObject(mac.command(value.toString()))
        try {
            withTimeout(20_000) { while (!phone.state.value.ready) delay(100) }
            phone.authenticate("fixture", true)
            withTimeout(20_000) { while (phone.relay.state.value.device.isEmpty()) delay(100) }
            val peer = phone.relay.state.value.device
            macCall(CoreRequest.create("fixture"))
            macCall(CoreRequest.relayInit("hub", "fixture", "mac", "mac"))
            macCall(CoreRequest.relayTrust(peer))
            phone.command(CoreRequest.relayInit("mobile", "fixture", peer, "mac"))
            phone.command(CoreRequest.relayTrust("mac"))
            macCall(CoreRequest.save(JSONObject().put("id", "from-mac").put("type", "secureNote").put("title", "Mac note")))
            // An unconfirmed legacy edit on the phone: exactly the "待提交" state users saw.
            phone.command(CoreRequest.save(JSONObject().put("id", "from-phone").put("type", "secureNote").put("title", "Phone offline note")))
            assertTrue(phone.command(CoreRequest.relayStatus()).getInt("pending") > 0)
            macCall(CoreRequest.relayMeshInit("fixture", "mac"))
            macCall(CoreRequest.relayMeshPeers(org.json.JSONArray().put(peer)))
            assertEquals("mobile", phone.command(CoreRequest.relayMeshInit("fixture", peer)).getString("migratedFrom"))
            phone.command(CoreRequest.relayMeshPeers(org.json.JSONArray().put("mac")))
            repeat(3) {
                macCall(CoreRequest.relayMeshExport(peer)).optJSONObject("packet")?.let {
                    phone.command(CoreRequest.relayMeshReceive("mac", it))
                }
                phone.command(CoreRequest.relayMeshExport("mac")).optJSONObject("packet")?.let {
                    macCall(CoreRequest.relayMeshReceive(peer, it))
                }
            }
            fun ids(list: JSONObject) = (0 until list.getJSONArray("items").length()).map { list.getJSONArray("items").getJSONObject(it).getString("id") }.toSet()
            assertTrue(ids(phone.command(CoreRequest.list())).containsAll(setOf("from-mac", "from-phone")))
            assertTrue(ids(macCall(CoreRequest.list())).containsAll(setOf("from-mac", "from-phone")))
            val status = phone.command(CoreRequest.relayStatus())
            assertEquals("mesh", status.getString("mode"))
            assertEquals(0, status.getInt("pending"))
            assertTrue(File(directory, "phone/vault/before-mesh-sync/vault.sqlite").exists())
        } finally { phone.close(); mac.close(); directory.deleteRecursively() }
    }
    @Test fun conflictReminderRestoresAndClearsAfterMacBatchResolution() = runBlocking {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val directory = File(context.cacheDir, "conflict-fixture-${UUID.randomUUID()}")
        val phone = VaultRepository(context, File(directory, "phone"))
        val mac = VaultSession(File(directory, "mac").absolutePath)
        fun macCall(value: JSONObject) = JSONObject(mac.command(value.toString()))
        try {
            withTimeout(20_000) { while (!phone.state.value.ready) delay(100) }
            phone.authenticate("fixture", true)
            withTimeout(20_000) { while (phone.relay.state.value.device.isEmpty()) delay(100) }
            val peer = phone.relay.state.value.device
            macCall(CoreRequest.create("fixture"))
            macCall(CoreRequest.relayInit("hub", "fixture", "mac", "mac"))
            macCall(CoreRequest.relayTrust(peer))
            phone.command(CoreRequest.relayInit("mobile", "fixture", peer, "mac"))
            phone.command(CoreRequest.relayTrust("mac"))
            macCall(CoreRequest.save(JSONObject().put("id", "conflict").put("type", "secureNote").put("title", "Mac version")))
            phone.command(CoreRequest.save(JSONObject().put("id", "conflict").put("type", "secureNote").put("title", "Phone version")))
            val changes = phone.command(CoreRequest.relayExport("mac"))
            macCall(CoreRequest.relayReceive(peer, changes))
            suspend fun deliverAndReload() {
                val packet = macCall(CoreRequest.relayExport(peer))
                phone.command(CoreRequest.relayReceive("mac", packet))
                phone.relay.setUnlocked(false); phone.relay.setUnlocked(true)
                withTimeout(20_000) { while (phone.relay.state.value.device.isEmpty() || phone.relay.state.value.busy) delay(100) }
            }
            deliverAndReload()
            assertEquals(1, phone.relay.state.value.conflicts)
            val conflicts = macCall(CoreRequest.relayStatus()).getJSONObject("conflicts")
            macCall(CoreRequest.relayResolveBatch(org.json.JSONArray(conflicts.keys().asSequence().toList()), "local"))
            deliverAndReload()
            assertEquals(0, phone.relay.state.value.conflicts)
            assertEquals(0, phone.relay.state.value.pending)
        } finally { phone.close(); mac.close(); directory.deleteRecursively() }
    }
    @Test fun productionWSSInterop() = runBlocking {
        val args=InstrumentationRegistry.getArguments()
        val path=args.getString("relayConfigPath")
        org.junit.Assume.assumeTrue("Explicit QA fixture required", path!=null)
        val context=InstrumentationRegistry.getInstrumentation().targetContext
        val configs=org.json.JSONArray(File(path!!).readText());val mac=configs.getJSONObject(0);val phone=configs.getJSONObject(1)
        val directory=File(context.cacheDir,"wss-relay-test-${UUID.randomUUID()}")
        val privateDir=File(directory,"relay-private").apply{mkdirs()}
        val alias="pv-relay-"+RelayCore.hex(java.security.MessageDigest.getInstance("SHA-256").digest(directory.absolutePath.toByteArray())).take(32)
        val generator=javax.crypto.KeyGenerator.getInstance("AES","AndroidKeyStore")
        generator.init(android.security.keystore.KeyGenParameterSpec.Builder(alias,android.security.keystore.KeyProperties.PURPOSE_ENCRYPT or android.security.keystore.KeyProperties.PURPOSE_DECRYPT).setBlockModes("GCM").setEncryptionPaddings("NoPadding").build())
        val key=generator.generateKey()
        val config=JSONObject().put("secret",phone.getString("secret_key")).put("group",phone.getString("group")).put("device",phone.getString("device")).put("hub",mac.getString("device")).put("endpoint",phone.getString("url")).put("token",phone.getString("token")).put("paused",false).put("peers",JSONObject().put(mac.getString("device"),mac.getString("public_key")))
        val cipher=javax.crypto.Cipher.getInstance("AES/GCM/NoPadding").apply{init(javax.crypto.Cipher.ENCRYPT_MODE,key)}
        File(privateDir,"identity.sealed").writeBytes(cipher.iv+cipher.doFinal(config.toString().toByteArray()))
        val vault=VaultRepository(context,directory)
        try {
            withTimeout(20000){while(!vault.state.value.ready)delay(100)}
            vault.authenticate("fixture",true)
            assertTrue(vault.state.value.unlocked)
            vault.command(CoreRequest.relayInit("mobile",phone.getString("group"),phone.getString("device"),mac.getString("device")))
            vault.command(CoreRequest.relayTrust(mac.getString("device")))
            withTimeout(120000){while(vault.state.value.entries.none{it.optString("id")=="android-large"})delay(500)}
            assertEquals(315000,vault.state.value.entries.first{it.optString("id")=="android-large"}.getString("note").length)
            assertTrue(vault.save(JSONObject().put("id","android-roundtrip").put("type","secureNote").put("title","Android to Mac")))
            withTimeout(120000){while(vault.state.value.entries.none{it.optString("id")=="android-ack"})delay(500)}
            assertNotNull(vault.relay.state.value.lastReceived)
        } finally {vault.close();directory.deleteRecursively();java.security.KeyStore.getInstance("AndroidKeyStore").apply{load(null);deleteEntry(alias)}}
    }
    @Test fun managedPresenceDoesNotRequireVaultAuthorization() = runBlocking {
        // A production `wss://` relay, or a loopback one via `adb reverse` (ws://127.0.0.1:PORT/v2/ws).
        val endpoint = InstrumentationRegistry.getArguments().getString("presenceEndpoint")
        org.junit.Assume.assumeTrue(endpoint?.startsWith("wss://") == true || endpoint?.startsWith("ws://127.0.0.1:") == true)
        RelayLocalTest.enabled = endpoint!!.startsWith("ws://")
        val access = InstrumentationRegistry.getArguments().getString("relayPassword") ?: "fixture-access-123"
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val base = File(context.cacheDir, "presence-fixture-${UUID.randomUUID()}")
        val a = VaultRepository(context, File(base, "owner"))
        val b = VaultRepository(context, File(base, "phone"))
        suspend fun until(condition: () -> Boolean) {
            withTimeout(40_000) { while (!condition()) delay(100) }
        }
        fun allOnline(v: VaultRepository) = v.relay.state.value.members.size == 2 && v.relay.state.value.members.all { it.online }
        try {
            until { a.state.value.ready && b.state.value.ready }
            a.authenticate("fixture", true); b.authenticate("fixture", true)
            a.relay.createGroup(endpoint, "Presence test fixture", "Fixture owner", access)
            until { a.relay.state.value.managed && a.relay.state.value.members.any { it.online } && !a.relay.state.value.busy }
            a.relay.inviteToGroup()
            until { a.relay.state.value.groupInvite.isNotEmpty() && !a.relay.state.value.busy }
            b.relay.joinGroup(a.relay.state.value.groupInvite, "Fixture phone", access)
            until { allOnline(a) && allOnline(b) }
            // Joining is the only step: both devices sync without any grant.
            until { a.relay.state.value.mesh && b.relay.state.value.mesh }
            assertTrue(a.relay.state.value.paired); assertTrue(b.relay.state.value.paired)
            withTimeout(40_000) { while (a.command(CoreRequest.relayStatus()).optString("mode") != "mesh" || b.command(CoreRequest.relayStatus()).optString("mode") != "mesh") delay(100) }
            val phoneID = b.relay.state.value.device
            b.relay.setUnlocked(false)
            until { a.relay.state.value.members.any { it.id == phoneID && !it.online } }
            b.relay.setUnlocked(true)
            until { allOnline(a) && allOnline(b) }
            assertEquals("mesh", b.command(CoreRequest.relayStatus()).optString("mode"))
        } finally {
            if (a.relay.state.value.managed) {
                until { !a.relay.state.value.busy }
                a.relay.leaveGroup(true)
                until { !a.relay.state.value.managed }
            }
            a.close(); b.close(); base.deleteRecursively()
            for (name in listOf("owner", "phone")) {
                val alias = "pv-relay-" + RelayCore.hex(java.security.MessageDigest.getInstance("SHA-256").digest(File(base, name).absolutePath.toByteArray())).take(32)
                java.security.KeyStore.getInstance("AndroidKeyStore").apply { load(null); deleteEntry(alias) }
            }
            RelayLocalTest.enabled = false
        }
    }
    /**
     * HyperOS freezes backgrounded apps and the relay then drops their socket. Returning to the
     * foreground must reconnect promptly and keep two-way sync working.
     */
    @Test fun foregroundReconnectsAfterTheRelayDroppedTheSocket() = runBlocking {
        val endpoint = InstrumentationRegistry.getArguments().getString("presenceEndpoint")
        org.junit.Assume.assumeTrue(endpoint?.startsWith("ws://127.0.0.1:") == true)
        RelayLocalTest.enabled = true
        val access = InstrumentationRegistry.getArguments().getString("relayPassword") ?: "fixture-access-123"
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val base = File(context.cacheDir, "reconnect-fixture-${UUID.randomUUID()}")
        val mac = VaultRepository(context, File(base, "mac"))
        val phone = VaultRepository(context, File(base, "phone"))
        suspend fun until(timeout: Long = 40_000, condition: () -> Boolean) { withTimeout(timeout) { while (!condition()) delay(100) } }
        fun online(v: VaultRepository) = v.relay.state.value.members.size == 2 && v.relay.state.value.members.all { it.online }
        fun has(v: VaultRepository, id: String) = v.state.value.entries.any { it.optString("id") == id }
        try {
            until { mac.state.value.ready && phone.state.value.ready }
            mac.authenticate("fixture", true); phone.authenticate("fixture", true)
            mac.relay.createGroup(endpoint!!, "Reconnect fixture", "Mac", access)
            until { mac.relay.state.value.managed && !mac.relay.state.value.busy }
            mac.relay.inviteToGroup()
            until { mac.relay.state.value.groupInvite.isNotEmpty() && !mac.relay.state.value.busy }
            phone.relay.joinGroup(mac.relay.state.value.groupInvite, "Phone", access)
            until { online(mac) && online(phone) && mac.relay.state.value.mesh && phone.relay.state.value.mesh }
            // A spent invitation retires on its own: no manual "cancel invitation" after the scan.
            until { mac.relay.state.value.groupInvite.isEmpty() }

            // Simulate the OS freeze: the relay closed the phone's socket while it was backgrounded.
            val field = PersonalRelay::class.java.getDeclaredField("client").apply { isAccessible = true }
            (field.get(phone.relay) as com.securepass.vault.core.RelayConnection).disconnect()
            val started = System.currentTimeMillis()
            phone.foreground()
            until(15_000) { phone.relay.state.value.status.contains("已连接") && phone.relay.state.value.error == null }
            val reconnectMs = System.currentTimeMillis() - started
            android.util.Log.w("PersonalRelayTest", "reconnected after ${reconnectMs}ms")
            assertTrue("reconnect took ${reconnectMs}ms", reconnectMs < 10_000)

            // Sync still flows both ways after the reconnect.
            assertTrue(mac.save(VaultRepository.blank("secureNote").put("id", "from-mac").put("title", "From Mac")))
            assertTrue(phone.save(VaultRepository.blank("secureNote").put("id", "from-phone").put("title", "From phone")))
            mac.relay.syncNow(); phone.relay.syncNow()
            until(60_000) { has(phone, "from-mac") && has(mac, "from-phone") }
        } finally {
            if (mac.relay.state.value.managed) { until { !mac.relay.state.value.busy }; mac.relay.leaveGroup(true) }
            mac.close(); phone.close(); base.deleteRecursively()
            for (name in listOf("mac", "phone")) {
                val alias = "pv-relay-" + RelayCore.hex(java.security.MessageDigest.getInstance("SHA-256").digest(File(base, name).absolutePath.toByteArray())).take(32)
                java.security.KeyStore.getInstance("AndroidKeyStore").apply { load(null); deleteEntry(alias) }
            }
            RelayLocalTest.enabled = false
        }
    }
    @Test fun legacyKeystoreMigratesToMasterPasswordFileAndRestartsWithoutLegacyKey() = runBlocking {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val base = File(context.cacheDir, "relay-migration-${UUID.randomUUID()}")
        val legacyDir = File(base, "relay-private").apply { mkdirs() }
        val alias = "pv-relay-" + RelayCore.hex(java.security.MessageDigest.getInstance("SHA-256").digest(base.absolutePath.toByteArray())).take(32)
        val keyStore = java.security.KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        val generator = javax.crypto.KeyGenerator.getInstance("AES", "AndroidKeyStore")
        generator.init(android.security.keystore.KeyGenParameterSpec.Builder(alias, android.security.keystore.KeyProperties.PURPOSE_ENCRYPT or android.security.keystore.KeyProperties.PURPOSE_DECRYPT)
            .setBlockModes("GCM").setEncryptionPaddings("NoPadding").build())
        val key = generator.generateKey()
        val legacy = JSONObject().put("secret", RelayCore.hex(RelayCore.random(32)))
            .put("device", "migration-fixture").put("group", "").put("hub", "").put("endpoint", "").put("token", "")
            .put("paused", true).put("peers", JSONObject())
        val cipher = javax.crypto.Cipher.getInstance("AES/GCM/NoPadding").apply { init(javax.crypto.Cipher.ENCRYPT_MODE, key) }
        File(legacyDir, "identity.sealed").writeBytes(cipher.iv + cipher.doFinal(legacy.toString().toByteArray()))
        var repository = VaultRepository(context, base)
        suspend fun ready() { withTimeout(20_000) { while (!repository.state.value.ready) delay(100) } }
        suspend fun migrated() { withTimeout(20_000) { while (repository.relay.state.value.device != "migration-fixture") delay(100) } }
        try {
            ready(); assertTrue(repository.relay.state.value.publicKey.isEmpty())
            repository.authenticate("fixture", true); migrated()
            val stored = File(base, "vault/relay-private/credentials.v1.enc")
            val encrypted = stored.readBytes().toString(Charsets.UTF_8)
            assertFalse(encrypted.contains("migration-fixture")); assertFalse(encrypted.contains(legacy.getString("secret")))
            assertEquals("migration-fixture", JSONObject(repository.command(CoreRequest.relayCredentialsRead()).getString("data")).getString("device"))
            repository.close()
            keyStore.deleteEntry(alias); File(legacyDir, "identity.sealed").delete()
            repository = VaultRepository(context, base); ready()
            repository.authenticate("fixture", false); migrated()
            assertFalse(repository.relay.state.value.credentialsBlocked)
        } finally { repository.close(); base.deleteRecursively(); if (keyStore.containsAlias(alias)) keyStore.deleteEntry(alias) }
    }
    @Test fun coreReplicationAndSecureIdentity() = runBlocking {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val base = File(context.cacheDir, "relay-test-${UUID.randomUUID()}").apply { mkdirs() }
        fun call(core: VaultSession, request: JSONObject) = JSONObject(core.command(request.toString()))
        try {
            VaultSession(File(base,"mac").absolutePath).use { mac ->
                VaultSession(File(base,"phone").absolutePath).use { phone ->
                    for ((core,role,device) in listOf(Triple(mac,"hub","mac"),Triple(phone,"mobile","phone"))) {
                        call(core,CoreRequest.create("fixture"))
                        call(core,CoreRequest.relayInit(role,"fixture",device,"mac"))
                        call(core,CoreRequest.relayTrust(if (role=="hub") "phone" else "mac"))
                    }
                    call(phone,CoreRequest.save(JSONObject().put("id","fixture").put("type","password").put("title","ANDROID_RELAY_CANARY")))
                    val packet = call(phone,CoreRequest.relayExport("mac"))
                    repeat(2) { call(mac,CoreRequest.relayReceive("phone",packet)) }
                    assertEquals(1,call(mac,CoreRequest.list()).getJSONArray("items").length())
                    call(phone,CoreRequest.relayReceive("mac",call(mac,CoreRequest.relayExport("phone"))))
                    assertEquals(0,call(phone,CoreRequest.relayStatus()).getInt("pending"))
                }
            }
            val repository=VaultRepository(context,File(base,"identity"))
            val relay=repository.relay
            assertTrue(relay.state.value.publicKey.isEmpty())
            withTimeout(20000) { while (!repository.state.value.ready) delay(100) }
            repository.authenticate("fixture", true)
            withTimeout(20000) { while(relay.state.value.publicKey.isEmpty() && relay.state.value.error==null) delay(100) }
            assertNull(relay.state.value.error); assertEquals(64,relay.state.value.publicKey.length)
            val encoded=File(base,"identity/vault/relay-private/credentials.v1.enc").readBytes().toString(Charsets.ISO_8859_1)
            assertFalse(encoded.contains("secret"));assertFalse(encoded.contains(relay.state.value.publicKey))
            repository.close()
        } finally { base.deleteRecursively() }
    }
}
