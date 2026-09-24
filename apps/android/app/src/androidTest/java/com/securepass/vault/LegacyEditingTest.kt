package com.securepass.vault

import android.content.Intent
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.uiautomator.By
import androidx.test.uiautomator.UiDevice
import androidx.test.uiautomator.Until
import java.io.File
import java.util.UUID
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class LegacyEditingTest {
    private var previousIdleTimeout = 10000L

    @org.junit.Before
    fun prepareDynamicUi() {
        val config = androidx.test.uiautomator.Configurator.getInstance()
        previousIdleTimeout = config.waitForIdleTimeout
        config.setWaitForIdleTimeout(400)
    }

    @org.junit.After
    fun restoreUiConfiguration() {
        androidx.test.uiautomator.Configurator.getInstance()
            .setWaitForIdleTimeout(previousIdleTimeout)
    }

    private val inst
        get() = InstrumentationRegistry.getInstrumentation()

    private val context
        get() = inst.targetContext

    private val device
        get() = UiDevice.getInstance(inst)

    private fun fresh() {
        if (android.os.Build.VERSION.SDK_INT >= 33) inst.uiAutomation.clearCache()
    }

    private fun scroll(up: Boolean = true) {
        fresh()
        val bounds =
            device.findObject(By.scrollable(true))?.visibleBounds ?: error("Missing scrolling form")
        device.swipe(
            bounds.centerX(),
            if (up) bounds.bottom - 90 else bounds.centerY(),
            bounds.centerX(),
            if (up) bounds.centerY() else bounds.bottom - 90,
            100,
        )
        android.os.SystemClock.sleep(250)
        fresh()
    }

    private fun locate(
        selector: androidx.test.uiautomator.BySelector
    ): androidx.test.uiautomator.UiObject2 {
        repeat(22) {
            fresh()
            val node = device.wait(Until.findObject(selector), 800)
            if (node != null && node.visibleBounds.height() > 20) return node
            scroll()
        }
        error("Control missing: $selector")
    }

    private fun set(label: String, value: String) {
        var field = locate(By.desc(label))
        while (field.className != "android.widget.EditText") field =
            field.parent ?: error("No editable ancestor for $label")
        field.text = value
        android.os.SystemClock.sleep(200)
    }

    private fun click(text: String) {
        val b = locate(By.text(text)).visibleBounds
        device.click(b.centerX(), b.centerY())
        android.os.SystemClock.sleep(250)
        fresh()
    }

    private fun shot(name: String) {
        device.takeScreenshot(File(context.getExternalFilesDir(null), "legacy-$name.png"))
    }

    private fun live(scenario: ActivityScenario<MainActivity>): VaultRepository {
        lateinit var result: VaultRepository
        scenario.onActivity { activity ->
            val field =
                MainActivity::class.java.getDeclaredField("vault").apply { isAccessible = true }
            result = field.get(activity) as VaultRepository
        }
        return result
    }

    @Test
    fun migratedCodeCanEditLoginFieldsAndBatchImportValidatesAllLines() = runBlocking {
        val id = UUID.randomUUID().toString()
        val directory = File(context.cacheDir, "ui-test-$id")
        var repo = VaultRepository(context, directory)
        while (!repo.state.value.ready) delay(10)
        repo.authenticate("1", true)
        val item =
            VaultRepository.blank("totp")
                .put("title", "迁移验证码")
                .put("username", "main")
                .put("password", "old-main")
                .put("secret", "JBSWY3DPEHPK3PXP")
                .put("period", 30)
                .put("passwordDuration", 120)
                .put(
                    "accounts",
                    JSONArray()
                        .put(
                            JSONObject()
                                .put("id", "code-extra")
                                .put("username", "extra")
                                .put("password", "old-extra")
                        ),
                )
        assertTrue(repo.save(item))
        repo.close()
        val scenario =
            ActivityScenario.launch<MainActivity>(
                Intent(context, MainActivity::class.java)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK)
                    .putExtra("uiTestVault", id)
                    .putExtra("qaScreenshots", true)
            )
        try {
            assertTrue(device.wait(Until.hasObject(By.text("解锁资料库")), 10000))
            device.findObject(By.clazz("android.widget.EditText")).text = "1"
            device.wait(Until.findObject(By.text("解锁").enabled(true)), 5000).click()
            device.wait(Until.findObject(By.desc("验证码")), 10000).click()
            device.wait(Until.findObject(By.text("迁移验证码")), 5000).longClick()
            click("编辑")
            assertTrue(device.wait(Until.hasObject(By.text("编辑验证码")), 5000))
            set("密码", "new-main")
            set("密码 2", "new-extra")
            shot("code-login-fields")
            device.findObject(By.text("保存")).click()
            assertTrue(device.wait(Until.hasObject(By.text("迁移验证码")), 7000))
            repo = live(scenario)
            val saved = repo.state.value.entries.single()
            assertEquals("new-main", saved.getString("password"))
            assertEquals(
                "old-main",
                saved.getJSONArray("passwordHistory").getJSONObject(0).getString("password"),
            )
            assertEquals(120, saved.getInt("passwordDuration"))
            val extra = saved.getJSONArray("accounts").getJSONObject(0)
            assertEquals("code-extra", extra.getString("id"))
            assertEquals("new-extra", extra.getString("password"))
            assertEquals(
                "old-extra",
                extra.getJSONArray("passwordHistory").getJSONObject(0).getString("password"),
            )
            assertEquals("JBSWY3DPEHPK3PXP", saved.getString("secret"))
            device.findObject(By.desc("资料工具")).click()
            click("批量导入验证码")
            val first = "otpauth://totp/BatchA:fixture?secret=JBSWY3DPEHPK3PXP&issuer=BatchA"
            val second = "otpauth://totp/BatchB:fixture?secret=JBSWY3DPEHPK3PXP&issuer=BatchB"
            device.findObject(By.clazz("android.widget.EditText")).text = first + "\ninvalid"
            device.findObject(By.text("导入")).click()
            assertTrue(device.wait(Until.hasObject(By.text("第 2 行无效，尚未导入。")), 5000))
            assertEquals(1, repo.state.value.entries.size)
            device.findObject(By.clazz("android.widget.EditText")).text = first + "\n" + second
            device.findObject(By.text("导入")).click()
            assertTrue(device.wait(Until.hasObject(By.text("已导入 2 / 2 项")), 10000))
            assertEquals(3, repo.state.value.entries.size)
        } catch (failure: Throwable) {
            shot("code-migration-failure")
            device.dumpWindowHierarchy(
                File(context.getExternalFilesDir(null), "legacy-code-migration-failure.xml")
            )
            throw failure
        } finally {
            scenario.close()
            repo.close()
            directory.deleteRecursively()
        }
    }

    @Test
    fun longSelectionAndEmptySharedFilterKeepCollectionUsable() = runBlocking {
        val id = UUID.randomUUID().toString()
        val directory = File(context.cacheDir, "ui-test-$id")
        var repo = VaultRepository(context, directory)
        while (!repo.state.value.ready) delay(10)
        repo.authenticate("1", true)
        repeat(24) { n ->
            assertTrue(
                repo.save(
                    VaultRepository.blank("password")
                        .put("title", "滚动账号%02d".format(n))
                        .put("username", "user$n")
                        .put("email", "email$n@example.test")
                        .put("password", "fictional-secret-$n")
                )
            )
        }
        repo.command(
            "create-shared",
            JSONObject().put("name", "空共享库").put("time", "2025-01-01T00:00:00Z"),
        )
        repo.close()
        val scenario =
            ActivityScenario.launch<MainActivity>(
                Intent(context, MainActivity::class.java)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK)
                    .putExtra("uiTestVault", id)
                    .putExtra("qaScreenshots", true)
            )
        try {
            assertTrue(device.wait(Until.hasObject(By.text("解锁资料库")), 10000))
            device.findObject(By.clazz("android.widget.EditText")).text = "1"
            device.wait(Until.findObject(By.text("解锁").enabled(true)), 5000).click()
            assertTrue(device.wait(Until.hasObject(By.text("全部资料库")), 10000))
            click("全部资料库")
            click("空共享库")
            click("清除筛选")
            assertTrue(device.hasObject(By.text("全部资料库")))
            val sort = device.findObject(By.desc("排序")).visibleBounds
            device.click(sort.centerX(), sort.centerY())
            click("按标题")
            click("选择")
            assertFalse(device.hasObject(By.desc("新建")))
            click("滚动账号00")
            click("滚动账号20")
            repeat(26) { if (!device.hasObject(By.text("已选 2 项"))) scroll(false) }
            assertTrue(device.hasObject(By.text("已选 2 项")))
            shot("long-selection")
            click("添加标签")
            device.findObject(By.clazz("android.widget.EditText")).text = "批量保留"
            device.findObject(By.text("确认")).click()
            assertTrue(device.wait(Until.hasObject(By.text("已完成 2 / 2 项")), 10000))
            repo = live(scenario)
            val changed = repo.state.value.entries.filter { "批量保留" in entryTags(it) }
            assertEquals(setOf("滚动账号00", "滚动账号20"), changed.map { it.getString("title") }.toSet())
            assertEquals(
                "titleAsc",
                repo.state.value.settings.getJSONObject("collectionSort").getString("password"),
            )
            // A changed search must not retain invisible selected records.
            click("滚动账号00")
            repeat(8) { if (!device.hasObject(By.text("已选 1 项"))) scroll(false) }
            val search = device.findObject(By.clazz("android.widget.EditText"))
            search.text = "email12@example.test"
            assertTrue(device.wait(Until.hasObject(By.text("滚动账号12")), 5000))
            assertFalse(device.hasObject(By.text("滚动账号00")))
            assertTrue(device.hasObject(By.text("已选 0 项")))
            click("完成选择")
        } catch (failure: Throwable) {
            shot("collection-failure")
            device.dumpWindowHierarchy(
                File(context.getExternalFilesDir(null), "legacy-collection-failure.xml")
            )
            throw failure
        } finally {
            scenario.close()
            repo.close()
            directory.deleteRecursively()
        }
    }

    @Test
    fun directEditingAdditionalAccountsAndRecoveryPreserveLegacyFields() = runBlocking {
        val id = UUID.randomUUID().toString()
        val directory = File(context.cacheDir, "ui-test-$id")
        var repo = VaultRepository(context, directory)
        while (!repo.state.value.ready) delay(10)
        repo.authenticate("1", true)
        val original =
            VaultRepository.blank("password")
                .put("title", "迁移完整账号")
                .put("username", "primary@example.test")
                .put("password", "original-primary")
                .put("email", "bound@example.test")
                .put("url", "https://one.example.test;https://two.example.test/path")
                .put("category", "工作")
                .put("tags", JSONArray(listOf("标签甲", "标签乙")))
                .put("colorLabel", "蓝色")
                .put("isPinned", true)
                .put("secret", "JBSWY3DPEHPK3PXP")
                .put("period", 30)
                .put("passwordDuration", 90)
                .put("passwordLastChanged", "2025-01-01T00:00:00Z")
                .put(
                    "passwordHistory",
                    JSONArray()
                        .put(
                            JSONObject()
                                .put("password", "older-primary")
                                .put("changedAt", "2024-01-01T00:00:00Z")
                        ),
                )
                .put("legacyExtra", JSONObject().put("retained", true))
                .put(
                    "accounts",
                    JSONArray()
                        .put(
                            JSONObject()
                                .put("id", "additional-a")
                                .put("username", "a@example.test")
                                .put("password", "original-a")
                                .put("label", "工作用途")
                                .put(
                                    "passwordHistory",
                                    JSONArray().put(JSONObject().put("password", "older-a")),
                                )
                        )
                        .put(
                            JSONObject()
                                .put("id", "additional-b")
                                .put("username", "b@example.test")
                                .put("password", "original-b")
                                .put("label", "待移除")
                        ),
                )
        assertTrue(repo.save(original))
        assertTrue(
            java.time.Instant.parse(repo.state.value.entries.single().getString("updatedAt"))
                .plusSeconds(90L * 86400)
                .toEpochMilli() > 0
        )
        repo.close()
        val scenario =
            ActivityScenario.launch<MainActivity>(
                Intent(context, MainActivity::class.java)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK)
                    .putExtra("uiTestVault", id)
                    .putExtra("qaScreenshots", true)
            )
        try {
            assertTrue(device.wait(Until.hasObject(By.text("解锁资料库")), 10000))
            device.findObject(By.clazz("android.widget.EditText")).text = "1"
            device.wait(Until.findObject(By.text("解锁").enabled(true)), 5000).click()
            assertTrue(device.wait(Until.hasObject(By.text("迁移完整账号")), 10000))
            click("迁移完整账号")
            assertTrue(device.wait(Until.hasObject(By.text("编辑账号")), 5000))
            assertFalse(device.hasObject(By.desc("编辑")))
            set("账号名称", "迁移修改完成")
            set("密码", "changed-primary")
            shot("direct-editor")
            set("用途 2", "修改后的工作用途")
            set("密码 2", "changed-a")
            click("添加另一个账号")
            set("用途 4", "新增用途")
            set("用户名 4", "new@example.test")
            set("密码 4", "new-additional")
            // Move back to the preceding account's remove control; no positional field IDs are
            // saved.
            scroll(false)
            val remove = locate(By.desc("移除账号 3"))
            val rb = remove.visibleBounds
            device.click(rb.centerX(), rb.centerY())
            assertTrue(device.wait(Until.hasObject(By.text("移除此附加账号？")), 3000))
            device.findObject(By.text("移除")).click()
            set("邮箱", "updated@example.test")
            shot("additional-fields")
            scenario.recreate()
            assertTrue(device.wait(Until.hasObject(By.text("编辑账号")), 5000))
            device.findObject(By.text("保存")).click()
            assertTrue(device.wait(Until.hasObject(By.text("迁移修改完成")), 7000))
            click("迁移修改完成")
            assertTrue(device.wait(Until.hasObject(By.text("编辑账号")), 5000))
            set("账号名称", "不应落盘的取消编辑")
            device.findObject(By.desc("返回")).click()
            assertTrue(device.wait(Until.hasObject(By.text("保存这次修改？")), 3000))
            device.findObject(By.text("放弃修改")).click()
            assertTrue(device.wait(Until.hasObject(By.text("迁移修改完成")), 5000))
            repo = live(scenario)
        } catch (failure: Throwable) {
            shot("failure")
            device.dumpWindowHierarchy(
                File(context.getExternalFilesDir(null), "legacy-failure.xml")
            )
            throw failure
        } finally {
            scenario.close()
            repo.close()
        }
        repo = VaultRepository(context, directory)
        while (!repo.state.value.ready) delay(10)
        repo.authenticate("1", false)
        val saved = repo.state.value.entries.single()
        assertEquals("迁移修改完成", saved.getString("title"))
        assertEquals(original.getString("id"), saved.getString("id"))
        assertEquals("updated@example.test", saved.getString("email"))
        for (field in
            listOf(
                "url",
                "category",
                "tags",
                "colorLabel",
                "isPinned",
                "secret",
                "period",
                "passwordDuration",
                "legacyExtra",
            )) assertEquals(
            "Preserve $field",
            original.get(field).toString(),
            saved.get(field).toString(),
        )
        assertEquals(
            "original-primary",
            saved.getJSONArray("passwordHistory").getJSONObject(0).getString("password"),
        )
        assertEquals(
            "older-primary",
            saved.getJSONArray("passwordHistory").getJSONObject(1).getString("password"),
        )
        val extra = saved.getJSONArray("accounts").objects()
        assertEquals(2, extra.size)
        val a = extra.single { it.optString("id") == "additional-a" }
        assertEquals("修改后的工作用途", a.getString("label"))
        assertEquals(
            "original-a",
            a.getJSONArray("passwordHistory").getJSONObject(0).getString("password"),
        )
        assertEquals(
            "older-a",
            a.getJSONArray("passwordHistory").getJSONObject(1).getString("password"),
        )
        assertFalse(extra.any { it.optString("id") == "additional-b" })
        val added = extra.single { it.optString("username") == "new@example.test" }
        assertTrue(added.getString("id").isNotBlank())
        assertEquals("新增用途", added.getString("label"))
        assertEquals("new-additional", added.getString("password"))
        repo.close()
    }

    @Test
    fun walletSourceRecoveryAndDeletionUsePersistedContent() = runBlocking {
        val id = UUID.randomUUID().toString()
        val directory = File(context.cacheDir, "ui-test-$id")
        var repo = VaultRepository(context, directory)
        while (!repo.state.value.ready) delay(10)
        repo.authenticate("1", true)
        val phrase = List(23) { "abandon" }.plus("art").joinToString(" ")
        val derived =
            repo.command("wallet", JSONObject().put("mnemonic", phrase).put("generate", false))
        val item =
            VaultRepository.blank("crypto")
                .put("title", "二十四词迁移钱包")
                .put("mnemonic", phrase)
                .put("privateKey", derived.getString("privateKey"))
                .put("address", derived.getString("address"))
                .put("network", "ETH")
                .put("note", "保留备注")
        assertTrue(repo.save(item))
        val expected =
            repo
                .command(
                    "wallet",
                    JSONObject()
                        .put("privateKey", "2".repeat(64))
                        .put("mnemonic", "")
                        .put("generate", false),
                )
                .getString("address")
        repo.close()
        val scenario =
            ActivityScenario.launch<MainActivity>(
                Intent(context, MainActivity::class.java)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK)
                    .putExtra("uiTestVault", id)
                    .putExtra("qaScreenshots", true)
            )
        try {
            assertTrue(device.wait(Until.hasObject(By.text("解锁资料库")), 10000))
            device.findObject(By.clazz("android.widget.EditText")).text = "1"
            device.wait(Until.findObject(By.text("解锁").enabled(true)), 5000).click()
            device.wait(Until.findObject(By.desc("钱包")), 10000).click()
            click("二十四词迁移钱包")
            assertTrue(device.wait(Until.hasObject(By.text("编辑钱包")), 5000))
            set("私钥", "2".repeat(64))
            scenario.recreate() // Recovery retains which credential was being edited.
            assertTrue(device.wait(Until.hasObject(By.text("编辑钱包")), 5000))
            device.wait(Until.findObject(By.text("保存").enabled(true)), 8000).click()
            assertTrue(device.wait(Until.hasObject(By.text("二十四词迁移钱包")), 5000))
            repo = live(scenario)
            val saved = repo.state.value.entries.single()
            assertEquals("2".repeat(64), saved.getString("privateKey"))
            assertEquals(expected, saved.getString("address"))
            assertEquals(phrase, saved.getString("mnemonic"))
            assertFalse(saved.has("_walletEditSource"))
            click("二十四词迁移钱包")
            set("钱包名称", "不能保存的草稿名称")
            scenario.recreate()
            assertTrue(device.wait(Until.hasObject(By.text("编辑钱包")), 5000))
            click("移到回收站…")
            device.wait(Until.findObject(By.text("删除")), 3000).click()
            assertTrue(device.wait(Until.gone(By.text("编辑钱包")), 5000))
            repo = live(scenario)
            val deleted = repo.state.value.entries.single()
            assertTrue(deleted.getBoolean("isDeleted"))
            assertEquals("二十四词迁移钱包", deleted.getString("title"))
            assertTrue(repo.trash(deleted))
            assertTrue(device.wait(Until.hasObject(By.text("二十四词迁移钱包")), 5000))
            shot("wallet-restored")
        } catch (failure: Throwable) {
            shot("wallet-failure")
            device.dumpWindowHierarchy(
                File(context.getExternalFilesDir(null), "legacy-wallet-failure.xml")
            )
            throw failure
        } finally {
            scenario.close()
            repo.close()
        }
        repo = VaultRepository(context, directory)
        while (!repo.state.value.ready) delay(10)
        repo.authenticate("1", false)
        val reopened = repo.state.value.entries.single()
        assertFalse(reopened.optBoolean("isDeleted"))
        assertEquals("二十四词迁移钱包", reopened.getString("title"))
        assertEquals(phrase, reopened.getString("mnemonic"))
        assertEquals(expected, reopened.getString("address"))
        repo.close()
    }
}
