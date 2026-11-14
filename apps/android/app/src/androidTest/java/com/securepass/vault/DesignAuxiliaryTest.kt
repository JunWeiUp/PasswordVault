package com.securepass.vault

import android.content.Intent
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.uiautomator.By
import androidx.test.uiautomator.BySelector
import androidx.test.uiautomator.Direction
import androidx.test.uiautomator.StaleObjectException
import androidx.test.uiautomator.UiDevice
import androidx.test.uiautomator.UiObject2
import androidx.test.uiautomator.Until
import java.io.File
import java.util.UUID
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith

/** Real entry points only: no relay endpoint, invitation, simulated grant or external service. */
@RunWith(AndroidJUnit4::class)
class DesignAuxiliaryTest {
    @Test fun accountMenusHistoryShareAndSelection() = runBlocking<Unit> {
        withFixture("accounts") {
            action("账号")
            click(ACCOUNT)
            action("更多操作")
            visible("临时分享")
            shot("item")
            click("版本历史")
            visible("查看版本")
            shot("hist")
            back()
            action("更多操作")
            click("临时分享")
            visible("分享服务配置")
            // An unconfigured fixture opens configuration by default; toggling would close it.
            scrollTo(By.text("分享服务地址（HTTPS）"))
            visible("分享服务地址（HTTPS）")
            // Opening configuration is local. Never check/save a service or create a link.
            assertFalse(device.hasObject(By.text("复制完整链接")))
            shot("share")
            back()
            scrollTo(By.textStartsWith("密码历史（"))
            tap(By.textStartsWith("密码历史（"))
            visible("收起密码历史")
            assertFalse("Previous passwords must remain hidden", device.hasObject(By.text(OLD_PASSWORD)))
            shot("pwhist")
            // Password history is an inline expansion in the current native detail page.
            click("收起密码历史")
            action("更多操作")
            click("移到回收站")
            visible("移到回收站？")
            shot("del")
            click("取消")
            back()
            visible(ACCOUNT)
            action("资料工具")
            click("选择")
            // Selection automatically dismisses CollectionTools via LaunchedEffect.
            visible("已选择 0 项")
            click(ACCOUNT)
            visible("已选择 1 项")
            click(SECOND_ACCOUNT)
            visible("已选择 2 项")
            shot("multi")
            action("取消选择")
            device.findObjects(By.clazz(EDIT_TEXT)).first().text = "aux-no-matches-$id"
            visible("没有找到“aux-no-matches-$id”")
            hideKeyboard()
            shot("search0")
            action("清空搜索")
            visible(ACCOUNT)
            visible(SECOND_ACCOUNT)
        }
    }

    @Test fun walletManualCodeAndFormatSevenDevice() = runBlocking<Unit> {
        withFixture("wallet-code-device", devices = true) {
            action("钱包")
            click("新建")
            visible("新建钱包项目")
            visible("加密货币钱包")
            shot("walletNew")
            back()
            visible(WALLET)
            click(WALLET)
            scrollTo(By.desc("显示助记词"))
            action("显示助记词")
            visible("显示助记词？")
            shot("words")
            click("取消")
            assertFalse(device.hasObject(By.text("1  abandon")))
            back()
            action("验证码")
            click("添加")
            visible("手动输入密钥")
            click("手动输入密钥")
            fillAny(listOf("发行方"), "辅助验证码")
            fillAny(listOf("账号"), "aux@example.test")
            fillAny(listOf("密钥（Base32）"), "A".repeat(32))
            // Use the form's action instead of Back, which also controls sheet visibility.
            scrollTo(By.text("取消"))
            click("取消")
            visible("保存这次修改？")
            shot("discard")
            click("继续编辑")
            assertTrue(device.wait(Until.gone(By.text("保存这次修改？")), 5_000))
            scrollTo(By.clazz(EDIT_TEXT).text("辅助验证码"))
            node(By.clazz(EDIT_TEXT).text("辅助验证码"))
            scrollTo(By.clazz(EDIT_TEXT).text("aux@example.test"))
            node(By.clazz(EDIT_TEXT).text("aux@example.test"))
            scrollTo(By.text("密钥（Base32）"))
            assertFalse("Setup secret must remain concealed", device.hasObject(By.text("A".repeat(32))))
            shot("manual")
            scrollTo(By.text("添加"))
            assertTrue("Valid retained draft must be addable", node(By.text("添加")).isEnabled)
            click("添加")
            visible("辅助验证码")
            // Confirm the add survives opening the real detail page.
            val details = device.wait(Until.findObject(By.desc("详情")), 8_000)
            assertNotNull("Saved code must expose its detail action", details)
            details.click()
            visible("辅助验证码")
            visible("aux@example.test")
            back()
            action("笔记")
            action("打开导航")
            settle(800)
            scrollTo(By.text("设备与服务"))
            val destination = node(By.text("设备与服务"))
            (destination.parent ?: destination).click()
            assertTrue(device.wait(Until.gone(By.text("全部项目")), 8_000))
            visible(DEVICE); shot("dev")
            click(DEVICE)
            visible("fixture.example.test")
            assertFalse("Device password must be concealed", device.hasObject(By.text(DEVICE_PASSWORD)))
            shot("dev-detail")
        }
    }

    @Test fun unconfiguredSyncAboutRecoveryAndLockErrors() = runBlocking<Unit> {
        withFixture("settings-recovery-lock") {
            action("设置")
            click("同步与设备")
            visible("加入设备组")
            assertFalse(device.hasObject(By.text("已获授权：查看并同步修改")))
            shot("s:relay")
            click("粘贴邀请链接")
            visible("邀请链接或内容")
            // No invitation is supplied and no request is submitted.
            shot("join")
            back()
            // Root navigation is a reliable semantic marker even when Settings is scrolled.
            action("设置")
            scrollTo(By.text("通用"))
            visible("通用")
            scrollTo(By.text("关于"))
            click("关于")
            visible("安全模型")
            shot("s:about")
            back()
            action("设置")
            scrollTo(By.text("通用"))
            visible("通用")
            scrollTo(By.text("恢复密钥"))
            click("恢复密钥")
            click("生成恢复密钥") // Settings entry opens the actual recovery sheet.
            visible("尚未设置恢复密钥")
            click("生成恢复密钥") // Generate in the isolated vault only; leave the result concealed.
            visible("我已抄写")
            visible("显示密钥")
            shot("rk")
            click("我已抄写")
            visible("再次输入完整密钥")
            shot("rk2")
            // Both unlocked generation and locked reset currently use the real Cancel action.
            // Never reveal, copy, read, print, enable or persist the generated recovery key.
            click("取消")
            assertTrue(device.wait(Until.gone(By.text("再次输入完整密钥")), 5_000))
            back()
            action("设置")
            scrollTo(By.text("通用"))
            visible("通用")
            action("笔记")
            action("锁定")
            visible("PasswordVault 已锁定")
            device.findObjects(By.clazz(EDIT_TEXT)).first().text = "incorrect-fixture-password"
            action("解锁")
            node(By.textContains("密码不正确或资料库无法读取"))
            hideKeyboard()
            shot("lockerr")
            click("忘记主密码？")
            visible("用恢复密钥重设")
            visible("新主密码")
            shot("lockrec")
            // This is the genuine reset form, not a successful recovery without a valid key.
            click("取消")
            visible("PasswordVault 已锁定")
            device.findObjects(By.clazz(EDIT_TEXT)).first().text = "1"
            action("解锁")
            visible(NOTE)
        }
    }

    private suspend fun withFixture(name: String, devices: Boolean = false, block: suspend Session.() -> Unit) {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        val device = UiDevice.getInstance(instrumentation)
        val id = UUID.randomUUID().toString()
        val directory = File(context.cacheDir, "ui-test-$id")
        val preferences = context.getSharedPreferences("ui", 0)
        val hadChinese = preferences.contains("chinese")
        val chinese = preferences.getBoolean("chinese", true)
        var vault: VaultRepository? = null
        var scenario: ActivityScenario<MainActivity>? = null
        val session = Session(device, id, context.getExternalFilesDir(null) ?: error("Screenshot directory unavailable"))
        try {
            check(preferences.edit().putBoolean("chinese", true).commit())
            val fixture = VaultRepository(context, directory)
            vault = fixture
            withTimeout(15_000) { while (!fixture.state.value.ready) delay(10) }
            fixture.authenticate("1", true)
            assertTrue(fixture.state.value.unlocked)
            val theme = InstrumentationRegistry.getArguments().getString("designTheme") ?: "light"
            assertTrue(fixture.mutate("settings", JSONObject().put("settings", JSONObject().put("theme", theme))))
            fixture.command("history-enable")
            val account = VaultRepository.blank("password").put("title", ACCOUNT)
                .put("username", "aux@example.test").put("url", "https://example.test")
                .put("password", OLD_PASSWORD)
            assertTrue(fixture.save(prepareEntrySave(account, fixture.state.value.entries)))
            assertTrue(fixture.save(prepareEntrySave(JSONObject(account.toString()).put("password", "Current synthetic password #42"), fixture.state.value.entries)))
            assertTrue(fixture.save(VaultRepository.blank("password").put("title", SECOND_ACCOUNT).put("username", "second@example.test").put("password", "Second synthetic password #42")))
            assertTrue(fixture.save(VaultRepository.blank("secureNote").put("title", NOTE).put("note", "仅用于隔离测试，不包含真实资料。")))
            assertTrue(fixture.save(VaultRepository.blank("crypto").put("title", WALLET).put("network", "Ethereum").put("mnemonic", "abandon ".repeat(11) + "about")))
            if (devices) {
                fixture.command("devices-enable", JSONObject().put("confirm", true).put("currentPassword", "1"))
                val payload = JSONObject().put("version", 1).put("host", "fixture.example.test").put("port", 22)
                    .put("username", "fixture").put("authMethod", "password").put("password", DEVICE_PASSWORD)
                    .put("privateKey", "").put("notes", "仅复制，不执行")
                    .put("aliases", JSONArray()).put("services", JSONArray()).put("files", JSONArray())
                    .put("commands", JSONArray().put(JSONObject().put("id", "aux-command").put("title", "测试说明").put("text", "Inert synthetic document").put("secret", true)))
                assertTrue(fixture.save(VaultRepository.blank("device").put("title", DEVICE).put("device", payload)))
            }
            fixture.close()
            device.wakeUp()
            device.executeShellCommand("wm dismiss-keyguard")
            scenario = ActivityScenario.launch(
                Intent(context, MainActivity::class.java)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK)
                    .putExtra("uiTestVault", id).putExtra("qaScreenshots", true),
            )
            session.visible("PasswordVault 已锁定")
            device.findObjects(By.clazz(EDIT_TEXT)).first().text = "1"
            session.action("解锁")
            session.visible(NOTE)
            session.block()
        } catch (failure: Throwable) {
            // Recovery generation remains hidden, including in failure artifacts.
            runCatching { session.shot("aux-$name-failure") }
            runCatching { device.dumpWindowHierarchy(File(session.output, "align-aux-$name-failure.xml")) }
            throw failure
        } finally {
            try { scenario?.close() } finally {
                try { vault?.close() } finally {
                    try { directory.deleteRecursively() } finally {
                        val edit = preferences.edit()
                        if (hadChinese) edit.putBoolean("chinese", chinese) else edit.remove("chinese")
                        check(edit.commit()) { "Failed to restore Chinese UI preference" }
                    }
                }
            }
        }
    }

    private class Session(val device: UiDevice, val id: String, val output: File) {
        fun settle(milliseconds: Long = 300) { Thread.sleep(milliseconds); device.waitForIdle(2_000) }
        fun refreshAccessibility() {
            if (android.os.Build.VERSION.SDK_INT >= 33) InstrumentationRegistry.getInstrumentation().uiAutomation.clearCache()
        }
        fun node(selector: BySelector): UiObject2 {
            val deadline = android.os.SystemClock.elapsedRealtime() + 10_000
            while (android.os.SystemClock.elapsedRealtime() < deadline) {
                refreshAccessibility()
                device.findObject(selector)?.let { return it }
                Thread.sleep(150)
            }
            throw AssertionError("Expected auxiliary UI element: $selector")
        }
        fun visible(label: String) { node(By.text(label)) }
        fun tap(selector: BySelector) {
            settle(150)
            val bounds = node(selector).visibleBounds
            assertTrue("Target must have visible bounds: $selector", bounds.width() > 0 && bounds.height() > 0)
            // One gesture only: UiObject2 can become stale after a successful toggle.
            device.click(bounds.centerX(), bounds.centerY())
            settle()
        }
        fun click(label: String) = tap(By.text(label))
        fun action(label: String) = tap(By.desc(label))
        fun back() { device.pressBack(); settle(450) }
        fun hideKeyboard() {
            // Inspect visibility without assuming a keyboard package or dismissing a dialog.
            val windows = device.executeShellCommand("dumpsys window displays")
            if (Regex("""type=ime\b[^\n]*visible=true""").containsMatchIn(windows)) back()
            settle()
        }
        fun shot(scene: String) {
            settle(500)
            assertTrue("Screenshot write failed for $scene", device.takeScreenshot(File(output, "align-${scene.replace(':', '-')}.png")))
        }
        fun scrollTo(selector: BySelector) {
            for (direction in listOf(Direction.DOWN, Direction.UP)) repeat(10) {
                refreshAccessibility()
                if (device.hasObject(selector)) return
                val scrollable = device.findObjects(By.clazz("android.widget.ScrollView").scrollable(true)).lastOrNull()
                val bounds = scrollable?.visibleBounds
                val top = bounds?.let { it.top + it.height() / 4 } ?: (device.displayHeight / 3)
                val bottom = bounds?.let { it.bottom - it.height() / 4 } ?: (device.displayHeight * 3 / 4)
                val x = bounds?.centerX() ?: (device.displayWidth / 2)
                device.swipe(x, if (direction == Direction.DOWN) bottom else top,
                    x, if (direction == Direction.DOWN) top else bottom, 25)
                settle(350)
            }
            node(selector)
        }
        fun fillAny(labels: List<String>, value: String) {
            // Scroll the editor from its current position; never identify a secret by its value.
            repeat(14) {
                for (label in labels) {
                    // EditorField exposes its own accessible label even while empty.
                    // Searching an ancestor for any EditText can select an unrelated field.
                    val field = device.findObject(By.desc(label)) ?: continue
                    field.click()
                    settle()
                    val focused = node(By.clazz(EDIT_TEXT).focused(true))
                    focused.text = value
                    settle()
                    return
                }
                device.findObjects(By.scrollable(true)).lastOrNull()?.scroll(Direction.DOWN, 0.5f)
                settle(200)
            }
            throw AssertionError("Missing labeled editor field: ${labels.joinToString()}")
        }
    }

    private companion object {
        const val EDIT_TEXT = "android.widget.EditText"
        const val ACCOUNT = "辅助账号 GitHub"
        const val SECOND_ACCOUNT = "辅助账号 Mail"
        const val NOTE = "辅助验收笔记"
        const val WALLET = "辅助测试钱包"
        const val DEVICE = "辅助测试服务器"
        const val OLD_PASSWORD = "Previous synthetic password #17"
        const val DEVICE_PASSWORD = "Auxiliary synthetic device password"
    }
}
