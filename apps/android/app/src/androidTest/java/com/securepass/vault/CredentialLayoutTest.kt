package com.securepass.vault

import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
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
class CredentialLayoutTest {
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

    private val theme
        get() = InstrumentationRegistry.getArguments().getString("designTheme") ?: "light"

    private fun shot(name: String) {
        android.os.SystemClock.sleep(350)
        device.takeScreenshot(File(context.getExternalFilesDir(null), "details-$theme-$name.png"))
    }

    private fun fresh() {
        if (android.os.Build.VERSION.SDK_INT >= 33) inst.uiAutomation.clearCache()
    }

    private fun scroll(up: Boolean = true) {
        fresh()
        val bounds = device.findObject(By.scrollable(true)).visibleBounds
        val low = bounds.bottom - 60
        val high = bounds.centerY()
        device.swipe(
            bounds.centerX(),
            if (up) low else high,
            bounds.centerX(),
            if (up) high else low,
            100,
        )
        android.os.SystemClock.sleep(300)
        fresh()
    }

    private fun tapAction(description: String) {
        fresh()
        val bounds =
            device
                .findObjects(By.desc(description))
                .map { it.visibleBounds }
                .first {
                    it.height() > 0 && it.width() > 0 && it.centerY() < device.displayHeight - 100
                }
        device.click(bounds.centerX(), bounds.centerY())
        android.os.SystemClock.sleep(250)
        fresh()
    }

    private fun findText(text: String) {
        repeat(12) { if (!device.hasObject(By.text(text))) scroll() }
        assertTrue("Expected $text", device.hasObject(By.text(text)))
    }

    private fun findDesc(text: String) {
        repeat(12) { if (!device.hasObject(By.desc(text))) scroll() }
        assertTrue("Expected action $text", device.hasObject(By.desc(text)))
    }

    private fun start(id: String) =
        ActivityScenario.launch<MainActivity>(
            Intent(context, MainActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK)
                .putExtra("uiTestVault", id)
                .putExtra("qaScreenshots", true)
        )

    @Test
    fun longCollectionsScrollTogetherAndDetailsProtectSecrets() = runBlocking {
        val id = UUID.randomUUID().toString()
        val fixture = VaultRepository(context, File(context.cacheDir, "ui-test-$id"))
        while (!fixture.state.value.ready) delay(10)
        fixture.authenticate("1", true)
        assertTrue(
            fixture.mutate(
                "settings",
                JSONObject().put("settings", JSONObject().put("theme", theme)),
            )
        )
        for ((kind, prefix) in listOf("password" to "账号", "totp" to "验证码", "crypto" to "钱包")) {
            for (index in 29 downTo 0) {
                val item =
                    VaultRepository.blank(kind)
                        .put("title", "$prefix 样例 ${index.toString().padStart(2, '0')}")
                        .put("category", "工作")
                        .put("tags", JSONArray(listOf("个人")))
                        .put("username", "fictional@example.test")
                        .put("url", "https://example.test")
                        .put("note", "仅用于界面测试的虚构记录。")
                when (kind) {
                    "password" ->
                        item
                            .put("password", "FICTIONAL-PRIMARY-123") // gitleaks:allow -- public, synthetic UI fixture
                            .put("secret", "JBSWY3DPEHPK3PXP") // gitleaks:allow -- public, synthetic TOTP test secret
                            .put("email", "mail@example.test")
                            .put(
                                "accounts",
                                JSONArray()
                                    .put(
                                        JSONObject()
                                            .put("id", "extra")
                                            .put("label", "工作账号")
                                            .put("username", "work@example.test")
                                            .put("password", "FICTIONAL-EXTRA-456")
                                    ),
                            )
                            .put(
                                "passwordHistory",
                                JSONArray()
                                    .put(
                                        JSONObject()
                                            .put("password", "FICTIONAL-OLD-789")
                                            .put("changedAt", "Previous change")
                                    ),
                            )
                    "totp" -> item.put("secret", "JBSWY3DPEHPK3PXP") // gitleaks:allow -- public, synthetic TOTP test secret.put("period", 30)
                    "crypto" ->
                        item
                            .put("network", "ETH")
                            .put("address", "0x1111111111111111111111111111111111111111")
                            .put("privateKey", "1".repeat(64))
                            .put(
                                "mnemonic",
                                "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about",
                            )
                }
                assertTrue(fixture.save(item))
                // Keep instrumentation desugaring compatible with the application's date formatter.
                assertTrue(
                    java.time.Instant.parse(
                            fixture.state.value.entries.first().getString("updatedAt")
                        )
                        .toEpochMilli() > 0
                )
            }
        }
        fixture.close()
        val scenario = start(id)
        try {
            assertTrue(device.wait(Until.hasObject(By.text("解锁资料库")), 10000))
            device.findObject(By.clazz("android.widget.EditText")).text = "1"
            device.wait(Until.findObject(By.text("解锁").enabled(true)), 5000).click()
            if (!device.wait(Until.hasObject(By.text("账号 样例 00")), 10000)) {
                shot("unlock-failed")
                device.dumpWindowHierarchy(
                    File(context.getExternalFilesDir(null), "details-unlock-failed.xml")
                )
                error("Collection not visible after unlock")
            }
            for (label in listOf("账号", "验证码", "钱包")) {
                device.findObject(By.desc(label))?.click()
                android.os.SystemClock.sleep(500)
                fresh()
                assertTrue(device.wait(Until.hasObject(By.clazz("android.widget.EditText")), 5000))
                device
                    .findObject(
                        androidx.test.uiautomator.UiSelector().className("android.widget.EditText")
                    )
                    .setText("样例")
                shot("$label-before-scroll")
                scroll()
                assertFalse(
                    "Search must leave the viewport",
                    device.hasObject(By.clazz("android.widget.EditText")),
                )
                shot("$label-scrolled")
                val row = device.findObjects(By.textStartsWith("$label 样例")).first()
                val title = row.text
                if (label == "验证码") {
                    row.click()
                    scenario.onActivity { activity ->
                        val copied =
                            (activity.getSystemService(Context.CLIPBOARD_SERVICE)
                                    as ClipboardManager)
                                .primaryClip
                                ?.getItemAt(0)
                                ?.text
                                ?.toString()
                                .orEmpty()
                        assertTrue(copied.matches(Regex("[0-9]{6}")))
                    }
                    fresh()
                    device.findObject(By.text(title)).longClick()
                    device.wait(Until.findObject(By.text("编辑")), 3000).click()
                } else row.click()
                assertTrue(device.wait(Until.hasObject(By.text("编辑$label")), 5000))
                shot("$label-detail")
                when (label) {
                    "账号" -> {
                        assertFalse(device.hasObject(By.text("FICTIONAL-PRIMARY-123")))
                        findDesc("显示密码")
                        tapAction("显示密码")
                        findText("FICTIONAL-PRIMARY-123")
                        tapAction("隐藏密码")
                        findText("密码历史（1）")
                        device.findObject(By.text("密码历史（1）")).click()
                        assertFalse(device.hasObject(By.text("FICTIONAL-OLD-789")))
                        findText("附加账号")
                        shot("account-additional")
                    }
                    "验证码" -> {
                        findDesc("显示设置密钥")
                        assertFalse(device.hasObject(By.text("JBSWY3DPEHPK3PXP")))
                        tapAction("显示设置密钥")
                        findText("JBSWY3DPEHPK3PXP")
                        shot("code-settings")
                    }
                    "钱包" -> {
                        findDesc("复制钱包地址")
                        tapAction("复制钱包地址")
                        scenario.onActivity { activity ->
                            assertEquals(
                                "0x1111111111111111111111111111111111111111",
                                (activity.getSystemService(Context.CLIPBOARD_SERVICE)
                                        as ClipboardManager)
                                    .primaryClip
                                    ?.getItemAt(0)
                                    ?.text
                                    ?.toString(),
                            )
                        }
                        findDesc("显示私钥")
                        assertFalse(device.hasObject(By.text("1".repeat(64))))
                        tapAction("显示私钥")
                        findText("1".repeat(64))
                        findText("显示助记词")
                        device.findObject(By.text("显示助记词")).click()
                        findText("abandon")
                        shot("wallet-phrase")
                    }
                }
                device.findObject(By.desc("返回")).click()
                assertTrue(device.wait(Until.hasObject(By.text(title)), 5000))
                assertFalse(
                    "Return must preserve collection scroll position",
                    device.hasObject(By.clazz("android.widget.EditText")),
                )
                repeat(3) { scroll(false) }
                assertEquals("样例", device.findObject(By.clazz("android.widget.EditText")).text)
                device.findObject(By.desc("清空搜索")).click()
            }
            device.findObject(By.desc("设置")).click()
            assertTrue(device.wait(Until.hasObject(By.text("生物识别解锁")), 5000))
            shot("security")
            assertFalse(device.hasObject(By.text("启用 / 更新生物识别")))
        } catch (failure: Throwable) {
            shot("flow-failed")
            device.dumpWindowHierarchy(
                File(context.getExternalFilesDir(null), "details-flow-failed.xml")
            )
            throw failure
        } finally {
            scenario.close()
        }
    }

    @Test
    fun biometricControlStatesAreUnambiguous() {
        val enabled = mutableStateOf(false)
        val available = mutableStateOf(true)
        val busy = mutableStateOf(false)
        var toggle: Boolean? = null
        var renew = false
        val scenario = start(UUID.randomUUID().toString())
        try {
            scenario.onActivity { activity ->
                activity.setContent {
                    LegacyVaultTheme(dark = theme == "dark") {
                        Surface(Modifier.fillMaxSize()) {
                            Column(Modifier.padding(24.dp).padding(top = 48.dp)) {
                                BiometricControls(
                                    enabled.value,
                                    available.value,
                                    busy.value,
                                    null,
                                    { zh, _ -> zh },
                                    { toggle = it },
                                    { renew = true },
                                )
                            }
                        }
                    }
                }
            }
            assertTrue(device.wait(Until.hasObject(By.text("未开启")), 5000))
            assertFalse(device.hasObject(By.text("更新生物识别验证")))
            device.findObject(By.desc("生物识别解锁")).click()
            inst.waitForIdleSync()
            assertEquals(true, toggle)
            scenario.onActivity { busy.value = true }
            assertTrue(device.wait(Until.hasObject(By.text("等待验证…")), 3000))
            assertFalse(device.findObject(By.desc("生物识别解锁")).isEnabled)
            scenario.onActivity {
                busy.value = false
                enabled.value = true
            }
            assertTrue(device.wait(Until.hasObject(By.text("已开启")), 3000))
            device.findObject(By.text("更新生物识别验证")).click()
            inst.waitForIdleSync()
            assertTrue(renew)
            shot("biometric-enabled")
            scenario.onActivity { available.value = false }
            assertTrue(device.wait(Until.hasObject(By.textContains("当前不可用")), 3000))
            assertTrue(device.findObject(By.desc("生物识别解锁")).isEnabled)
            device.findObject(By.desc("生物识别解锁")).click()
            inst.waitForIdleSync()
            assertEquals(false, toggle)
            shot("biometric-unavailable")
        } finally {
            scenario.close()
        }
    }

    @Test
    fun biometricStateObservesExternalPreferenceChanges() = runBlocking {
        val fixture =
            VaultRepository(context, File(context.cacheDir, "bio-state-${UUID.randomUUID()}"))
        val prefs = context.getSharedPreferences("biometric-key", Context.MODE_PRIVATE)
        val oldPreferences = prefs.all
        var biometric: BiometricVault? = null
        val scenario = start(UUID.randomUUID().toString())
        try {
            scenario.onActivity { activity ->
                // Presentation fixture only: never use this value to authenticate or replace a key.
                prefs
                    .edit()
                    .putString("alias", "synthetic-state-only-${UUID.randomUUID()}")
                    .putString("ciphertext", "synthetic-state-only")
                    .commit()
                biometric = BiometricVault(activity)
                activity.setContent {
                    LegacyVaultTheme(dark = theme == "dark") {
                        Surface(Modifier.fillMaxSize()) {
                            Column(Modifier.padding(24.dp).padding(top = 48.dp)) {
                                BiometricSettings(biometric!!, fixture) { zh, _ -> zh }
                            }
                        }
                    }
                }
            }
            assertTrue(device.wait(Until.hasObject(By.text("已开启")), 5000))
            assertTrue(device.hasObject(By.text("更新生物识别验证")))
            // Password changes disable biometrics outside this component. Observe without a resume.
            scenario.onActivity { biometric!!.disable() }
            assertTrue(device.wait(Until.hasObject(By.text("未开启")), 3000))
            assertFalse(device.hasObject(By.text("更新生物识别验证")))
        } finally {
            scenario.close()
            val editor = prefs.edit().clear()
            oldPreferences.forEach { (key, value) ->
                if (value is String) editor.putString(key, value)
            }
            editor.commit()
            fixture.close()
        }
    }
}
