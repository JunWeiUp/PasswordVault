package com.securepass.vault

import android.app.Instrumentation
import android.content.ClipboardManager
import android.content.Intent
import android.content.IntentFilter
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.uiautomator.By
import androidx.test.uiautomator.UiDevice
import androidx.test.uiautomator.UiObject2
import androidx.test.uiautomator.UiScrollable
import androidx.test.uiautomator.UiSelector
import androidx.test.uiautomator.Until
import java.io.File
import java.util.UUID
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

/** Settings › General clipboard duration and start page, the offline banner, and About entries. */
@RunWith(AndroidJUnit4::class)
class SettingsGeneralTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val context = instrumentation.targetContext
    private val device = UiDevice.getInstance(instrumentation)

    private fun waitText(text: String, timeout: Long = 5_000): UiObject2 {
        val found = device.wait(Until.findObject(By.text(text)), timeout)
        if (found == null) device.dumpWindowHierarchy(File(context.getExternalFilesDir(null), "settings-general-${text.take(10)}.xml"))
        assertNotNull("Expected text: $text", found)
        return found!!
    }

    private fun launchAndUnlock(id: String) {
        context.startActivity(
            Intent(context, MainActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK)
                .putExtra("uiTestVault", id),
        )
        assertTrue(device.wait(Until.hasObject(By.text("PasswordVault 已锁定")), 10_000))
        device.findObject(By.clazz("android.widget.EditText")).text = "1"
        device.findObject(By.desc("解锁")).click()
        assertTrue(device.wait(Until.hasObject(By.desc("设置")), 10_000))
    }

    private fun goAccounts() {
        repeat(5) {
            if (device.hasObject(By.text("Prefs fixture"))) return
            if (!device.hasObject(By.desc("账号"))) device.pressBack()
            runCatching { device.findObject(By.desc("账号"))?.click() }
            device.wait(Until.hasObject(By.text("Prefs fixture")), 2_000)
        }
        waitText("Prefs fixture")
    }

    private fun choose(current: String, option: String) {
        waitText(current).click()
        waitText(option).click()
        device.waitForIdle()
    }

    @Test
    fun generalPreferencesOfflineBannerAndAbout() = runBlocking<Unit> {
        val prefs = context.getSharedPreferences(AppPreferences.FILE, 0)
        prefs.edit().remove(AppPreferences.CLIPBOARD_SECONDS).remove(AppPreferences.START_PAGE).remove(AppPreferences.LAST_PAGE).commit()
        val id = UUID.randomUUID().toString()
        val directory = File(context.cacheDir, "ui-test-$id")
        val fixture = VaultRepository(context, directory)
        try {
            withTimeout(15_000) { while (!fixture.state.value.ready) delay(25) }
            fixture.authenticate("1", true)
            withTimeout(15_000) { while (fixture.relay.state.value.device.isEmpty() || fixture.relay.state.value.busy) delay(25) }
            assertTrue(fixture.save(VaultRepository.blank("password").put("title", "Prefs fixture").put("username", "qa@example.test").put("password", "Fictional-only-" + "value-42")))
            // A personal group whose relay is a closed loopback port: joined, but unreachable.
            val config = JSONObject(fixture.command(CoreRequest.relayCredentialsRead()).getString("data"))
            val device = config.getString("device"); val secret = config.getString("secret")
            val keys = RelayCore.protocol(CoreRequest.relayProtocolKeys(secret))
            val own = JSONObject().put("device", device).put("name", "Phone").put("public_key", keys.getString("publicKey"))
                .put("signing_key", keys.getString("signingKey")).put("manager", true)
            val state = JSONObject().put("version", 1).put("app", "passwordvault").put("group", "fixture-group").put("name", "Fixture")
                .put("revision", 1).put("previous", "").put("members", org.json.JSONArray().put(own)).put("invitation", "").put("request_hash", "")
            val entry = RelayCore.protocol(CoreRequest.relayProtocolSign(state, secret, device)).getJSONObject("entry")
            val endpoint = "wss://127.0.0.1:1/v2/ws"; val token = "q".repeat(48)
            config.put("group", "fixture-group").put("endpoint", endpoint).put("token", token)
                .put("groups", JSONObject().put("app", "passwordvault").put("device", device).put("secret_key", secret).put("url", endpoint)
                    .put("group", "fixture-group").put("token", token).put("group_entry", entry).put("trusted_peers", JSONObject()))
            fixture.command(CoreRequest.relayCredentialsWrite(config.toString()))
        } finally { fixture.close() }

        try {
            launchAndUnlock(id)
            // Default start page is Notes; the failed relay shows the offline banner on lists.
            waitText("离线 · 修改先加密保存在本机", 30_000)
            goAccounts()
            assertTrue("Banner on the accounts list too", device.hasObject(By.text("离线 · 修改先加密保存在本机")))

            device.findObject(By.desc("设置")).click()
            waitText("通用").click()
            waitText("打开时显示")
            choose("笔记", "账号")
            choose("30 秒", "15 秒")
            assertEquals(15, prefs.getInt(AppPreferences.CLIPBOARD_SECONDS, -1))
            assertEquals("password", prefs.getString(AppPreferences.START_PAGE, null))
            device.pressBack()

            // About: release notes open the GitHub releases page; licenses are bundled.
            UiScrollable(UiSelector().scrollable(true)).scrollTextIntoView("关于")
            waitText("关于").click()
            val monitor = instrumentation.addMonitor(IntentFilter(Intent.ACTION_VIEW).apply { addDataScheme("https") }, Instrumentation.ActivityResult(0, null), true)
            try {
                waitText("更新日志").click()
                val until = System.currentTimeMillis() + 3_000
                while (monitor.hits < 1 && System.currentTimeMillis() < until) delay(100)
                assertEquals("Release notes open the browser once", 1, monitor.hits)
            } finally { instrumentation.removeMonitor(monitor) }
            waitText("开源许可").click()
            waitText("── LICENSE.txt ──")
            assertTrue(device.wait(Until.hasObject(By.textContains("MIT License")), 5_000))
            waitText("关闭").click()
            device.pressBack()

            // Copying uses the chosen 15-second duration and clears afterwards.
            goAccounts(); waitText("Prefs fixture").click()
            waitText("复制密码").click()
            assertTrue(device.wait(Until.hasObject(By.textContains("15 秒后清除")), 5_000))
            fun clip(): String { var text = ""; instrumentation.runOnMainSync { text = context.getSystemService(ClipboardManager::class.java).primaryClip?.takeIf { it.itemCount > 0 }?.getItemAt(0)?.text?.toString().orEmpty() }; return text }
            assertTrue("Copied", clip().startsWith("Fictional-only-"))
            val deadline = System.currentTimeMillis() + 25_000
            while (System.currentTimeMillis() < deadline && clip().isNotEmpty()) delay(500)
            assertEquals("Clipboard cleared after 15 seconds", "", clip())

            // After locking, the next unlock opens Accounts directly.
            backToNavigation(device)
            device.findObject(By.desc("笔记")).click()
            repeat(5) {
                if (device.hasObject(By.text("立即锁定"))) return@repeat
                device.wait(Until.hasObject(By.desc("打开导航")), 3_000)
                runCatching { device.findObject(By.desc("打开导航"))?.click() } // may go stale mid-animation
                device.wait(Until.hasObject(By.text("立即锁定")), 2_000)
            }
            repeat(5) {
                if (device.hasObject(By.text("PasswordVault 已锁定"))) return@repeat
                android.os.SystemClock.sleep(400)
                runCatching { device.findObject(By.text("立即锁定"))?.click() }
                device.wait(Until.hasObject(By.text("PasswordVault 已锁定")), 2_000)
            }
            waitText("PasswordVault 已锁定")
            // An unlock tapped while the previous session is still closing can be ignored; retry.
            repeat(4) {
                if (device.hasObject(By.text("Prefs fixture"))) return@repeat
                runCatching {
                    device.findObject(By.clazz("android.widget.EditText")).text = "1"
                    device.findObject(By.desc("解锁")).click()
                }
                device.wait(Until.hasObject(By.text("Prefs fixture")), 5_000)
            }
            waitText("Prefs fixture", 5_000)
            assertTrue("Accounts selected", device.findObject(By.desc("账号")).isSelected || device.hasObject(By.text("需关注")))
        } finally {
            prefs.edit().remove(AppPreferences.CLIPBOARD_SECONDS).remove(AppPreferences.START_PAGE).remove(AppPreferences.LAST_PAGE).commit()
        }
    }
}
