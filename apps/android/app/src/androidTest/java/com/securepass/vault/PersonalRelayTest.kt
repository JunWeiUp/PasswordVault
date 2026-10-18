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
    @Test fun deviceAccessGrantRejectsWrongAuthorityScopeAndReplay() = runBlocking {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val directory = File(context.cacheDir, "access-fixture-${UUID.randomUUID()}")
        val vault = VaultRepository(context, directory)
        try {
            withTimeout(20_000) { while (!vault.state.value.ready) delay(100) }
            vault.authenticate("fixture", true)
            withTimeout(20_000) { while (vault.relay.state.value.device.isEmpty()) delay(100) }
            val c = JSONObject(vault.command("relay-credentials-read").getString("data"))
            val key = io.github.junweiup.commonrelay.Crypto.hex(io.github.junweiup.commonrelay.Crypto.random(32))
            c.put("group", "access-test").put("groups", JSONObject()
                .put("trusted_peers", JSONObject().put("hub", key).put("ordinary", key))
                .put("vault_authority", JSONObject().put("device", "hub").put("public_key", key)))
            val field = PersonalRelay::class.java.getDeclaredField("epoch").apply { isAccessible = true }
            val generation = field.getInt(vault.relay)
            fun message(revision: Int, enabled: Boolean) = JSONObject().put("format", "passwordvault.access.v1")
                .put("kind", "set").put("permission", "read-write").put("group", "access-test")
                .put("to", c.getString("device")).put("revision", revision).put("enabled", enabled)
            assertFalse(vault.relay.receiveAuthorization(c, message(1, true), "ordinary", generation))
            assertFalse(vault.relay.receiveAuthorization(c, message(1, true).put("to", "other"), "hub", generation))
            assertFalse(vault.relay.receiveAuthorization(c, message(1, true).put("group", "other"), "hub", generation))
            assertFalse(vault.command("relay-status").optBoolean("enabled"))
            assertTrue(vault.relay.receiveAuthorization(c, message(1, true), "hub", generation))
            assertTrue(c.getJSONObject("peers").has("hub"))
            assertTrue(vault.relay.receiveAuthorization(c, message(2, false), "hub", generation))
            assertFalse(c.getJSONObject("peers").has("hub"))
            assertFalse(vault.relay.receiveAuthorization(c, message(1, true), "hub", generation))
            assertFalse(vault.relay.receiveAuthorization(c, message(2, true), "hub", generation))
            val persisted = JSONObject(vault.command("relay-credentials-read").getString("data"))
            assertEquals(2, persisted.getInt("access_revision")); assertFalse(persisted.getBoolean("access_enabled"))
            assertTrue(vault.relay.receiveAuthorization(c, message(3, true), "hub", generation))
            vault.relay.setUnlocked(false)
            assertFalse(vault.relay.receiveAuthorization(c, message(4, true), "hub", generation))
        } finally { vault.close(); directory.deleteRecursively() }
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
            a.relay.createGroup(endpoint!!, "Presence test fixture", "Fixture owner")
            until { a.relay.state.value.managed && a.relay.state.value.members.any { it.online } && !a.relay.state.value.busy }
            a.relay.inviteToGroup()
            until { a.relay.state.value.groupInvite.isNotEmpty() && !a.relay.state.value.busy }
            b.relay.joinGroup(a.relay.state.value.groupInvite, "Fixture phone")
            until { allOnline(a) && allOnline(b) }
            assertFalse(a.relay.state.value.paired); assertFalse(b.relay.state.value.paired)
            assertTrue(a.relay.state.value.paused); assertTrue(b.relay.state.value.paused)
            assertFalse(a.command("relay-status").optBoolean("enabled")); assertFalse(b.command("relay-status").optBoolean("enabled"))
            b.relay.pause(true)
            until { allOnline(a) && allOnline(b) }
            val phoneID = b.relay.state.value.device
            b.relay.setUnlocked(false)
            until { a.relay.state.value.members.any { it.id == phoneID && !it.online } }
            b.relay.setUnlocked(true)
            until { allOnline(a) && allOnline(b) }
            assertFalse(b.command("relay-status").optBoolean("enabled"))
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
