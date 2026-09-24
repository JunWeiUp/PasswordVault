package com.securepass.vault

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.io.File
import java.util.UUID
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class MigrationBehaviorTest {
    @Test
    fun explicitWalletOperationRejectsDelayedAutomaticResult() = runBlocking {
        val requests = WalletEditRequests()
        val oldRequest = requests.begin()
        val release = CompletableDeferred<Unit>()
        var credentials = "original"
        val old = launch {
            release.await()
            if (requests.owns(oldRequest)) credentials = "stale automatic result"
        }
        val explicit = requests.begin()
        if (requests.owns(explicit)) credentials = "generated wallet"
        release.complete(Unit)
        old.join()
        assertEquals("generated wallet", credentials)
        val current = requests.begin()
        assertFalse(requests.owns(explicit))
        assertTrue(requests.owns(current))
    }

    @Test
    fun providerCsvMappingsAndCodeUriRoundTrip() {
        val bitwarden =
            JSONArray(
                parseMigrationCsv(
                    "folder,type,name,notes,login_uri,login_username,login_password\r\nWork,login,Example,\"line one\nline \"\"two\"\"\",https://example.test,user,secret\r\nWork,card,Skipped,notes,,,\r\n",
                    "bitwarden",
                )
            )
        assertEquals(1, bitwarden.length())
        assertEquals("line one\nline \"two\"", bitwarden.getJSONObject(0).getString("note"))
        assertEquals("Work", bitwarden.getJSONObject(0).getString("category"))
        val one =
            JSONArray(
                    parseMigrationCsv(
                        "Title,Website URL,Login,Password,Vault,Notes\nSample,https://one.test,user,pw,Personal,memo\n",
                        "1password",
                    )
                )
                .getJSONObject(0)
        assertEquals("https://one.test", one.getString("url"))
        assertEquals("Personal", one.getString("category"))
        assertEquals("user", one.getString("username"))
        val last =
            JSONArray(
                    parseMigrationCsv(
                        "url,username,password,extra,name,grouping,fav\nhttps://last.test,u,p,memo,Last,Group,1\n",
                        "lastpass",
                    )
                )
                .getJSONObject(0)
        assertTrue(last.getBoolean("isFavorite"))
        assertEquals("memo", last.getString("note"))
        val headerless =
            JSONArray(
                parseMigrationCsv("https://last.test,u,p,memo,Headerless,Group\n", "lastpass")
            )
        assertEquals("Headerless", headerless.getJSONObject(0).getString("title"))
        assertFalse(headerless.getJSONObject(0).getBoolean("isFavorite"))
        val titled =
            JSONArray(
                parseMigrationCsv("name,title,password\nLogin,Display title,p\n", "1password")
            )
        assertEquals("Display title", titled.getJSONObject(0).getString("title"))
        val chrome =
            JSONArray(
                    parseMigrationCsv(
                        "name,url,username,password\nChrome,https://chrome.test,c,pass\n",
                        "chrome",
                    )
                )
                .getJSONObject(0)
        assertEquals("Chrome", chrome.getString("title"))
        val aliases =
            JSONArray(
                    parseMigrationCsv(
                        "name,origin,user,password\nAlias,https://alias.test,alias,p\n",
                        "chrome",
                    )
                )
                .getJSONObject(0)
        assertEquals("https://alias.test", aliases.getString("url"))
        assertEquals("alias", aliases.getString("username"))
        val noPassword =
            JSONArray(parseMigrationCsv("title,username,notes\nLogin only,user\n", "1password"))
                .getJSONObject(0)
        assertEquals("user", noPassword.getString("username"))
        assertEquals("", noPassword.getString("password"))
        assertThrows(IllegalArgumentException::class.java) {
            parseMigrationCsv("name,password\n\"broken,quote", "chrome")
        }
        assertThrows(IllegalArgumentException::class.java) {
            parseMigrationCsv("unsupported,headers\nx,y", "chrome")
        }
    }

    @Test
    fun batchesAreIdempotentRespectViewerRolesAndKeepMetadata() = runBlocking {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val base = File(context.cacheDir, "migration-behavior-${UUID.randomUUID()}")
        val owner = VaultRepository(context, File(base, "owner"))
        val viewer = VaultRepository(context, File(base, "viewer"))
        try {
            while (!owner.state.value.ready || !viewer.state.value.ready) delay(10)
            owner.authenticate("1", true)
            viewer.authenticate("1", true)
            val item =
                VaultRepository.blank("password")
                    .put("title", "Batch fixture")
                    .put("username", "fixture")
                    .put("password", "canary")
                    .put("email", "bound@example.test")
                    .put("tags", JSONArray(listOf("original")))
                    .put(
                        "accounts",
                        JSONArray()
                            .put(
                                JSONObject()
                                    .put("id", "stable-extra")
                                    .put("username", "extra")
                                    .put("password", "extra-canary")
                            ),
                    )
            assertTrue(owner.save(item))
            val ids = setOf(item.getString("id"))
            assertEquals(ids, applyCollectionBatch(owner, ids, "pin"))
            assertTrue(owner.state.value.entries.single().getBoolean("isPinned"))
            assertEquals(ids, applyCollectionBatch(owner, ids, "unpin"))
            assertEquals(ids, applyCollectionBatch(owner, ids, "tag", "new"))
            assertEquals(ids, applyCollectionBatch(owner, ids, "color", "蓝色"))
            assertEquals(ids, applyCollectionBatch(owner, ids, "color", ""))
            assertEquals(listOf("original", "new"), entryTags(owner.state.value.entries.single()))
            assertEquals(
                "stable-extra",
                owner.state.value.entries
                    .single()
                    .getJSONArray("accounts")
                    .getJSONObject(0)
                    .getString("id"),
            )
            assertEquals(ids, applyCollectionBatch(owner, ids, "delete"))
            assertEquals(ids, applyCollectionBatch(owner, ids, "delete"))
            assertTrue(
                "Repeat delete must never restore",
                owner.state.value.entries.single().getBoolean("isDeleted"),
            )
            assertEquals(
                "bound@example.test",
                owner.state.value.entries.single().getString("email"),
            )
            val ownerKey = owner.command("identity").getString("publicKey")
            val viewerKey = viewer.command("identity").getString("publicKey")
            val shared =
                owner
                    .command(
                        "create-shared",
                        JSONObject()
                            .put("name", "Readonly migration")
                            .put("time", "2025-01-01T00:00:00Z"),
                    )
                    .getString("id")
            owner.command(
                "add-member",
                JSONObject()
                    .put("vaultId", shared)
                    .put("publicKey", viewerKey)
                    .put("role", "viewer")
                    .put("name", "Fixture"),
            )
            val sharedItem =
                VaultRepository.blank("password")
                    .put("title", "Shared readonly")
                    .put("password", "shared-canary")
                    .put("sharedVaultId", shared)
            assertTrue(owner.save(sharedItem))
            val request =
                viewer.command(
                    "sync-request",
                    JSONObject().put("peerKey", ownerKey).put("vaultId", shared),
                )
            val packet = owner.command("sync-respond", JSONObject().put("packet", request))
            viewer.command(
                "sync-apply",
                JSONObject().put("packet", packet).put("peerKey", ownerKey).put("vaultId", shared),
            )
            viewer.refresh()
            assertFalse(viewer.canEdit(viewer.state.value.entries.single()))
            val snapshot = viewer.state.value.entries.single().toString()
            assertTrue(
                applyCollectionBatch(viewer, setOf(sharedItem.getString("id")), "delete").isEmpty()
            )
            assertEquals(snapshot, viewer.state.value.entries.single().toString())
            val code =
                VaultRepository.blank("totp")
                    .put("title", "服务 示例")
                    .put("username", "a+b@example.test")
                    .put("secret", "JBSWY3DPEHPK3PXP")
                    .put("period", 60)
            val parsed = owner.command("parse-totp", JSONObject().put("uri", totpSetupUri(code)))
            for (field in listOf("title", "username", "secret", "period")) assertEquals(
                code.get(field),
                parsed.get(field),
            )
            val csvBackup =
                owner
                    .command(
                        "export-csv-backup",
                        JSONObject().put("password", "fixture-backup-password"),
                    )
                    .getString("content")
            assertTrue(csvBackup.contains("PasswordVaultCSVBackup"))
            assertFalse(csvBackup.contains("shared-canary"))
            val previousCount = owner.state.value.entries.size
            assertFalse(
                owner.mutate(
                    "import",
                    JSONObject()
                        .put("kind", "json")
                        .put("content", csvBackup)
                        .put("password", "wrong-password"),
                )
            )
            assertEquals(previousCount, owner.state.value.entries.size)
            assertTrue(
                viewer.mutate(
                    "import",
                    JSONObject()
                        .put("kind", "json")
                        .put("content", csvBackup)
                        .put("password", "fixture-backup-password"),
                )
            )
            assertTrue(
                viewer.state.value.entries.any {
                    it.optString("title") == "Shared readonly" &&
                        it.optString("password") == "shared-canary"
                }
            )
            val imported =
                parseMigrationCsv(
                    "name,url,username,password\nFixture,https://example.test,user,pass\n",
                    "chrome",
                )
            assertTrue(
                owner.mutate(
                    "import",
                    JSONObject().put("kind", "json").put("content", imported).put("password", ""),
                )
            )
        } finally {
            owner.close()
            viewer.close()
            base.deleteRecursively()
        }
    }
}
