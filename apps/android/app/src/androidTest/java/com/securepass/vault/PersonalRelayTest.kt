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
            withTimeout(20000) { while(relay.state.value.publicKey.isEmpty() && relay.state.value.error==null) delay(100) }
            assertNull(relay.state.value.error); assertEquals(64,relay.state.value.publicKey.length)
            val encoded=File(base,"identity/relay-private/identity.sealed").readBytes().toString(Charsets.ISO_8859_1)
            assertFalse(encoded.contains("secret"));assertFalse(encoded.contains(relay.state.value.publicKey))
            repository.close()
        } finally { base.deleteRecursively() }
    }
}
