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
    @Test fun pendingRecordsSurvivePausedAndUnavailableManualSync() = runBlocking {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val directory = File(context.cacheDir, "sync-progress-${UUID.randomUUID()}")
        val vault = VaultRepository(context, directory)
        suspend fun loaded() = withTimeout(15_000) { while (vault.relay.state.value.device.isEmpty() || vault.relay.state.value.busy) delay(25) }
        try {
            withTimeout(15_000) { while (!vault.state.value.ready) delay(25) }
            vault.authenticate("fixture", true); loaded()
            val config = JSONObject(vault.command("relay-credentials-read").getString("data"))
            assertTrue(vault.save(VaultRepository.blank("secureNote").put("title", "Offline synthetic note")))
            vault.command("relay-init", JSONObject().put("role", "mobile").put("device", config.getString("device")).put("hub", "fixture-hub").put("group", "fixture-group"))
            vault.command("relay-trust", JSONObject().put("peer", "fixture-hub"))
            val pending = vault.command("relay-status").getInt("pending")
            // One note plus the category-set record; these are not two unsaved edits.
            assertEquals(2, pending)
            val peerKey = io.github.junweiup.commonrelay.Crypto("passwordvault", "fixture-group", "fixture-hub", "01".repeat(32), emptyMap()).publicKey()
            config.put("group", "fixture-group").put("hub", "fixture-hub").put("paused", true)
                .put("peers", JSONObject().put("fixture-hub", peerKey)).put("token", "")
            vault.command("relay-credentials-write", JSONObject().put("data", config.toString()))
            vault.relay.setUnlocked(false); vault.relay.setUnlocked(true); loaded()
            vault.relay.syncNow()
            assertEquals(RelaySyncPhase.PAUSED, vault.relay.state.value.sync.phase)
            assertEquals(pending, vault.command("relay-status").getInt("pending"))
            config.put("paused", false)
            vault.command("relay-credentials-write", JSONObject().put("data", config.toString()))
            vault.relay.setUnlocked(false); vault.relay.setUnlocked(true); loaded()
            vault.relay.syncNow()
            withTimeout(15_000) { while (vault.relay.state.value.sync.phase != RelaySyncPhase.BLOCKED) delay(25) }
            assertEquals(pending, vault.command("relay-status").getInt("pending"))
            // A closed loopback port exercises transport failure without any external service.
            config.put("paused", false).put("token", "q".repeat(48)).put("endpoint", "wss://127.0.0.1:1/relay/v1/ws")
            vault.command("relay-credentials-write", JSONObject().put("data", config.toString()))
            vault.relay.setUnlocked(false); vault.relay.setUnlocked(true); loaded()
            withTimeout(15_000) { while (vault.relay.state.value.sync.phase != RelaySyncPhase.FAILED) delay(25) }
            assertNotNull(vault.relay.state.value.error)
            assertNull(vault.relay.state.value.sync.lastSentAt)
            assertEquals(pending, vault.command("relay-status").getInt("pending"))
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
            val before = JSONObject(vault.command("relay-credentials-read").getString("data"))
            vault.relay.updateServerPassword(access)
            withTimeout(20_000) {
                while (JSONObject(vault.command("relay-credentials-read").getString("data")).optString("password") != access) delay(100)
            }
            vault.relay.setUnlocked(false)
            vault.relay.setUnlocked(true)
            withTimeout(20_000) { while (vault.relay.state.value.device.isEmpty() || vault.relay.state.value.busy) delay(100) }
            val after = JSONObject(vault.command("relay-credentials-read").getString("data"))
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
            macCall(JSONObject().put("op", "create").put("password", "fixture"))
            macCall(JSONObject().put("op", "relay-init").put("role", "hub").put("device", "mac").put("hub", "mac").put("group", "fixture"))
            macCall(JSONObject().put("op", "relay-trust").put("peer", peer))
            phone.command("relay-init", JSONObject().put("role", "mobile").put("device", peer).put("hub", "mac").put("group", "fixture"))
            phone.command("relay-trust", JSONObject().put("peer", "mac"))
            macCall(JSONObject().put("op", "save").put("item", JSONObject().put("id", "from-mac").put("type", "secureNote").put("title", "Mac note")))
            // An unconfirmed legacy edit on the phone: exactly the "待提交" state users saw.
            phone.command("save", JSONObject().put("item", JSONObject().put("id", "from-phone").put("type", "secureNote").put("title", "Phone offline note")))
            assertTrue(phone.command("relay-status").getInt("pending") > 0)
            macCall(JSONObject().put("op", "relay-mesh-init").put("group", "fixture").put("device", "mac"))
            macCall(JSONObject().put("op", "relay-mesh-peers").put("peers", org.json.JSONArray().put(peer)))
            assertEquals("mobile", phone.command("relay-mesh-init", JSONObject().put("group", "fixture").put("device", peer)).getString("migratedFrom"))
            phone.command("relay-mesh-peers", JSONObject().put("peers", org.json.JSONArray().put("mac")))
            repeat(3) {
                macCall(JSONObject().put("op", "relay-mesh-export").put("peer", peer)).optJSONObject("packet")?.let {
                    phone.command("relay-mesh-receive", JSONObject().put("peer", "mac").put("packet", it))
                }
                phone.command("relay-mesh-export", JSONObject().put("peer", "mac")).optJSONObject("packet")?.let {
                    macCall(JSONObject().put("op", "relay-mesh-receive").put("peer", peer).put("packet", it))
                }
            }
            fun ids(list: JSONObject) = (0 until list.getJSONArray("items").length()).map { list.getJSONArray("items").getJSONObject(it).getString("id") }.toSet()
            assertTrue(ids(phone.command("list")).containsAll(setOf("from-mac", "from-phone")))
            assertTrue(ids(macCall(JSONObject().put("op", "list"))).containsAll(setOf("from-mac", "from-phone")))
            val status = phone.command("relay-status")
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
            macCall(JSONObject().put("op", "create").put("password", "fixture"))
            macCall(JSONObject().put("op", "relay-init").put("role", "hub").put("device", "mac").put("hub", "mac").put("group", "fixture"))
            macCall(JSONObject().put("op", "relay-trust").put("peer", peer))
            phone.command("relay-init", JSONObject().put("role", "mobile").put("device", peer).put("hub", "mac").put("group", "fixture"))
            phone.command("relay-trust", JSONObject().put("peer", "mac"))
            macCall(JSONObject().put("op", "save").put("item", JSONObject().put("id", "conflict").put("type", "secureNote").put("title", "Mac version")))
            phone.command("save", JSONObject().put("item", JSONObject().put("id", "conflict").put("type", "secureNote").put("title", "Phone version")))
            val changes = phone.command("relay-export", JSONObject().put("peer", "mac"))
            macCall(JSONObject().put("op", "relay-receive").put("peer", peer).put("packet", changes))
            suspend fun deliverAndReload() {
                val packet = macCall(JSONObject().put("op", "relay-export").put("peer", peer))
                phone.command("relay-receive", JSONObject().put("peer", "mac").put("packet", packet))
                phone.relay.setUnlocked(false); phone.relay.setUnlocked(true)
                withTimeout(20_000) { while (phone.relay.state.value.device.isEmpty() || phone.relay.state.value.busy) delay(100) }
            }
            deliverAndReload()
            assertEquals(1, phone.relay.state.value.conflicts)
            val conflicts = macCall(JSONObject().put("op", "relay-status")).getJSONObject("conflicts")
            macCall(JSONObject().put("op", "relay-resolve-batch").put("choice", "local").put("conflicts", org.json.JSONArray(conflicts.keys().asSequence().toList())))
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
        val alias="pv-relay-"+io.github.junweiup.commonrelay.Crypto.hex(java.security.MessageDigest.getInstance("SHA-256").digest(directory.absolutePath.toByteArray())).take(32)
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
            vault.command("relay-init",JSONObject().put("role","mobile").put("device",phone.getString("device")).put("group",phone.getString("group")).put("hub",mac.getString("device")))
            vault.command("relay-trust",JSONObject().put("peer",mac.getString("device")))
            withTimeout(120000){while(vault.state.value.entries.none{it.optString("id")=="android-large"})delay(500)}
            assertEquals(315000,vault.state.value.entries.first{it.optString("id")=="android-large"}.getString("note").length)
            assertTrue(vault.save(JSONObject().put("id","android-roundtrip").put("type","secureNote").put("title","Android to Mac")))
            withTimeout(120000){while(vault.state.value.entries.none{it.optString("id")=="android-ack"})delay(500)}
            assertNotNull(vault.relay.state.value.lastReceived)
        } finally {vault.close();directory.deleteRecursively();java.security.KeyStore.getInstance("AndroidKeyStore").apply{load(null);deleteEntry(alias)}}
    }
    @Test fun managedPresenceDoesNotRequireVaultAuthorization() = runBlocking {
        val endpoint = InstrumentationRegistry.getArguments().getString("presenceEndpoint")
        org.junit.Assume.assumeTrue(endpoint?.startsWith("wss://") == true)
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
            a.relay.createGroup(endpoint!!, "Presence test fixture", "Fixture owner", "fixture-access-123")
            until { a.relay.state.value.managed && a.relay.state.value.members.any { it.online } && !a.relay.state.value.busy }
            a.relay.inviteToGroup()
            until { a.relay.state.value.groupInvite.isNotEmpty() && !a.relay.state.value.busy }
            b.relay.joinGroup(a.relay.state.value.groupInvite, "Fixture phone", "fixture-access-123")
            until { allOnline(a) && allOnline(b) }
            // Joining is the only step: both devices sync without any grant.
            until { a.relay.state.value.mesh && b.relay.state.value.mesh }
            assertTrue(a.relay.state.value.paired); assertTrue(b.relay.state.value.paired)
            withTimeout(40_000) { while (a.command("relay-status").optString("mode") != "mesh" || b.command("relay-status").optString("mode") != "mesh") delay(100) }
            val phoneID = b.relay.state.value.device
            b.relay.setUnlocked(false)
            until { a.relay.state.value.members.any { it.id == phoneID && !it.online } }
            b.relay.setUnlocked(true)
            until { allOnline(a) && allOnline(b) }
            assertEquals("mesh", b.command("relay-status").optString("mode"))
        } finally {
            if (a.relay.state.value.managed) {
                until { !a.relay.state.value.busy }
                a.relay.leaveGroup(true)
                until { !a.relay.state.value.managed }
            }
            a.close(); b.close(); base.deleteRecursively()
            for (name in listOf("owner", "phone")) {
                val alias = "pv-relay-" + io.github.junweiup.commonrelay.Crypto.hex(java.security.MessageDigest.getInstance("SHA-256").digest(File(base, name).absolutePath.toByteArray())).take(32)
                java.security.KeyStore.getInstance("AndroidKeyStore").apply { load(null); deleteEntry(alias) }
            }
        }
    }
    @Test fun legacyKeystoreMigratesToMasterPasswordFileAndRestartsWithoutLegacyKey() = runBlocking {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val base = File(context.cacheDir, "relay-migration-${UUID.randomUUID()}")
        val legacyDir = File(base, "relay-private").apply { mkdirs() }
        val alias = "pv-relay-" + io.github.junweiup.commonrelay.Crypto.hex(java.security.MessageDigest.getInstance("SHA-256").digest(base.absolutePath.toByteArray())).take(32)
        val keyStore = java.security.KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        val generator = javax.crypto.KeyGenerator.getInstance("AES", "AndroidKeyStore")
        generator.init(android.security.keystore.KeyGenParameterSpec.Builder(alias, android.security.keystore.KeyProperties.PURPOSE_ENCRYPT or android.security.keystore.KeyProperties.PURPOSE_DECRYPT)
            .setBlockModes("GCM").setEncryptionPaddings("NoPadding").build())
        val key = generator.generateKey()
        val legacy = JSONObject().put("secret", io.github.junweiup.commonrelay.Crypto.hex(io.github.junweiup.commonrelay.Crypto.random(32)))
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
            assertEquals("migration-fixture", JSONObject(repository.command("relay-credentials-read").getString("data")).getString("device"))
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
        fun call(core: VaultSession, op: String, args: JSONObject = JSONObject()) = JSONObject(core.command(args.put("op",op).toString()))
        try {
            VaultSession(File(base,"mac").absolutePath).use { mac ->
                VaultSession(File(base,"phone").absolutePath).use { phone ->
                    for ((core,role,device) in listOf(Triple(mac,"hub","mac"),Triple(phone,"mobile","phone"))) {
                        call(core,"create",JSONObject().put("password","fixture"))
                        call(core,"relay-init",JSONObject().put("role",role).put("device",device).put("hub","mac").put("group","fixture"))
                        call(core,"relay-trust",JSONObject().put("peer",if (role=="hub") "phone" else "mac"))
                    }
                    call(phone,"save",JSONObject().put("item",JSONObject().put("id","fixture").put("type","password").put("title","ANDROID_RELAY_CANARY")))
                    val packet = call(phone,"relay-export",JSONObject().put("peer","mac"))
                    repeat(2) { call(mac,"relay-receive",JSONObject().put("peer","phone").put("packet",packet)) }
                    assertEquals(1,call(mac,"list").getJSONArray("items").length())
                    call(phone,"relay-receive",JSONObject().put("peer","mac").put("packet",call(mac,"relay-export",JSONObject().put("peer","phone"))))
                    assertEquals(0,call(phone,"relay-status").getInt("pending"))
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
