package com.securepass.vault

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
import java.util.regex.Pattern
import java.util.UUID
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class MigrationUtilityTest {
    @Test
    fun scannerRejectsCancelledAndPausedCallbacksAndDeliversOnce() {
        val session = QrScanSession()
        session.resume()
        val cancelled = session.begin()!!
        session.close()
        assertFalse(session.accept(cancelled))
        session.resume()
        assertNull(session.begin())
        val live = QrScanSession()
        live.resume()
        val beforePause = live.begin()!!
        live.pause()
        live.resume()
        assertFalse(live.accept(beforePause))
        val invalid = live.begin()!!
        live.reject(invalid)
        val valid = live.begin()!!
        assertTrue(live.accept(valid))
        assertFalse(live.accept(valid))
        assertNull(live.begin())
    }

    @Test
    fun qrFramesAndGeneratorOptionsRoundTripThroughCore() = runBlocking {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val base = File(context.cacheDir, "utility-${UUID.randomUUID()}")
        val repo = VaultRepository(context, base)
        try {
            while (!repo.state.value.ready) delay(10)
            repo.authenticate("1", true)
            val uri = "otpauth://totp/Frame:fixture?secret=JBSWY3DPEHPK3PXP&issuer=Frame"
            val image =
                InstrumentationRegistry.getInstrumentation()
                    .context
                    .assets
                    .open("authenticator-qr.png")
                    .use { android.graphics.BitmapFactory.decodeStream(it) }
            val pixels = IntArray(480 * 480)
            image.getPixels(pixels, 0, 480, 0, 0, 480, 480)
            var bytes = ByteArray(pixels.size) { (pixels[it] and 255).toByte() }
            image.recycle()
            pixels.fill(0)
            repeat(4) {
                assertEquals(uri, decodeQrLuma(bytes, 480, 480))
                val rotated = ByteArray(bytes.size)
                for (y in 0 until 480) for (x in 0 until 480) rotated[x * 480 + 479 - y] =
                    bytes[y * 480 + x]
                bytes.fill(0)
                bytes = rotated
            }
            bytes.fill(255.toByte())
            assertNull(decodeQrLuma(bytes, 480, 480))
            val parsed = repo.command(CoreRequest.parseTotp(uri))
            assertEquals("JBSWY3DPEHPK3PXP", parsed.getString("secret"))
            listOf(
                    GeneratorOptions(4, true, false, false, false) to Regex("[A-Z]{4}"),
                    GeneratorOptions(64, false, true, false, false) to Regex("[a-z]{64}"),
                    GeneratorOptions(4, false, false, true, false) to Regex("[0-9]{4}"),
                    GeneratorOptions(64, false, false, false, true) to Regex("[^A-Za-z0-9]{64}"),
                )
                .forEach { (options, pattern) ->
                    assertTrue(
                        pattern.matches(
                            repo.command(options.request()).getString("password")
                        )
                    )
                }
            assertFalse(GeneratorOptions(4, false, false, false, false).enabled)
            // Word mode goes through the same core op and response key.
            listOf(
                    GeneratorOptions(passphrase = true) to Regex("[a-z]+(-[a-z]+){4}"),
                    GeneratorOptions(passphrase = true, words = 3, separator = " ", capitalize = true) to
                        Regex("[A-Z][a-z]+( [A-Z][a-z]+){2}"),
                    GeneratorOptions(passphrase = true, words = 10, separator = ".", number = true) to
                        Regex("[a-z]+[0-9]?(\\.[a-z]+[0-9]?){9}"),
                )
                .forEach { (options, pattern) ->
                    val phrase = repo.command(options.request()).getString("password")
                    assertTrue(phrase, pattern.matches(phrase))
                    if (options.number) assertEquals(phrase, 1, phrase.count { it.isDigit() })
                }
            assertTrue(
                runCatching {
                        repo.command(GeneratorOptions(passphrase = true, words = 11).request())
                    }
                    .isFailure
            )
        } finally {
            repo.close()
            base.deleteRecursively()
        }
    }

    @Test
    fun passphraseFillsTheEditorDraftThroughUseThisPassword() = runBlocking {
        val inst = InstrumentationRegistry.getInstrumentation()
        val context = inst.targetContext
        val device = UiDevice.getInstance(inst)
        val utilityBase = File(context.cacheDir, "utility-${UUID.randomUUID()}")
        val repo = VaultRepository(context, utilityBase)
        while (!repo.state.value.ready) delay(10)
        repo.authenticate("1", true)
        val used = mutableStateOf<String?>(null)
        val scenario =
            ActivityScenario.launch<MainActivity>(
                Intent(context, MainActivity::class.java)
                    .putExtra("uiTestVault", UUID.randomUUID().toString())
                    .putExtra("qaScreenshots", true)
            )
        try {
            scenario.onActivity { activity ->
                activity.setContent {
                    LegacyVaultTheme(dark = false) {
                        Surface(Modifier.fillMaxSize().safeDrawingPadding().padding(20.dp)) {
                            PasswordGeneratorControls(repo, { zh, _ -> zh }, onUse = { used.value = it })
                        }
                    }
                }
            }
            assertTrue(device.wait(Until.hasObject(By.text("单词组合")), 8000))
            device.findObject(By.text("单词组合")).click()
            val shown = device.wait(Until.findObject(By.text(Pattern.compile("[a-z]+(-[a-z]+){4}"))), 5000)
            assertNotNull("Passphrase shown", shown)
            val phrase = shown.text
            device.findObject(By.text("使用这个密码")).click()
            val deadline = System.currentTimeMillis() + 5000
            while (used.value == null && System.currentTimeMillis() < deadline) delay(50)
            assertEquals(phrase, used.value)
        } catch (failure: Throwable) {
            device.dumpWindowHierarchy(File(context.getExternalFilesDir(null), "passphrase-use-failure.xml"))
            throw failure
        } finally {
            scenario.close()
            repo.close()
            utilityBase.deleteRecursively()
        }
    }

    @Test
    fun liveCameraCanCloseAndGeneratorDisablesAllOff() = runBlocking {
        val inst = InstrumentationRegistry.getInstrumentation()
        val context = inst.targetContext
        val device = UiDevice.getInstance(inst)
        val id = UUID.randomUUID().toString()
        val base = File(context.cacheDir, "ui-test-$id")
        val utilityBase = File(context.cacheDir, "utility-${UUID.randomUUID()}")
        val repo = VaultRepository(context, utilityBase)
        while (!repo.state.value.ready) delay(10)
        repo.authenticate("1", true)
        inst.uiAutomation.grantRuntimePermission(
            context.packageName,
            android.Manifest.permission.CAMERA,
        )
        val open = mutableStateOf(true)
        val scenario =
            ActivityScenario.launch<MainActivity>(
                Intent(context, MainActivity::class.java)
                    .putExtra("uiTestVault", id)
                    .putExtra("qaScreenshots", true)
            )
        try {
            scenario.onActivity { activity ->
                activity.setContent {
                    LegacyVaultTheme(dark = false) {
                        if (open.value)
                            LiveQrScanner(
                                repo,
                                { zh, _ -> zh },
                                { error("Emulator scene must not produce a setup QR") },
                                { open.value = false },
                            )
                        else
                            Surface(Modifier.fillMaxSize().safeDrawingPadding().padding(20.dp)) {
                                PasswordGeneratorControls(repo, { zh, _ -> zh })
                            }
                    }
                }
            }
            assertTrue(device.wait(Until.hasObject(By.text("扫描验证码")), 8000))
            assertTrue(device.wait(Until.hasObject(By.text("正在扫描")), 10000))
            assertFalse(device.hasObject(By.textContains("相机暂不可用")))
            device.takeScreenshot(File(context.getExternalFilesDir(null), "legacy-live-camera.png"))
            device.findObject(By.text("关闭")).click()
            val switches = listOf("大写字母 A–Z", "小写字母 a–z", "数字 0–9", "符号 !@#…")
            assertTrue(device.wait(Until.hasObject(By.desc(switches.first())), 5000))
            // Retry dropped taps by reading the switch state rather than toggling blindly.
            // The accessibility cache can report a switch's previous state, so clear it first.
            fun fresh() {
                if (android.os.Build.VERSION.SDK_INT >= 33) inst.uiAutomation.clearCache()
            }
            fun setSwitch(label: String, on: Boolean) {
                repeat(5) {
                    fresh()
                    val node = device.wait(Until.findObject(By.desc(label)), 3000)
                    if (node.isChecked == on) return
                    node.click()
                    android.os.SystemClock.sleep(300)
                }
                fresh()
                assertTrue("$label checked=$on", device.hasObject(By.desc(label).checked(on)))
            }
            for (label in switches) setSwitch(label, false)
            assertTrue(device.wait(Until.hasObject(By.text("至少选择一种字符类型")), 5000))
            assertFalse(device.findObject(By.text("重新生成")).parent.isEnabled)
            assertFalse(device.findObject(By.text("复制")).parent.isEnabled)
            device.takeScreenshot(
                File(context.getExternalFilesDir(null), "legacy-generator-disabled.png")
            )
            setSwitch("数字 0–9", true)
            assertTrue(device.wait(Until.gone(By.text("至少选择一种字符类型")), 5000))
            // Word mode: switching hides the character classes and shows a passphrase.
            device.findObject(By.text("单词组合")).click()
            assertTrue(device.wait(Until.hasObject(By.text("单词数 5")), 5000))
            assertFalse(device.hasObject(By.desc("大写字母 A–Z")))
            assertTrue(device.hasObject(By.textContains("2048 个英文单词")))
            assertTrue(device.wait(Until.hasObject(By.text(Pattern.compile("[a-z]+(-[a-z]+){4}"))), 5000))
            device.findObject(By.desc("分隔符 .")).click()
            setSwitch("首字母大写", true)
            setSwitch("加入一个数字", true)
            assertTrue(
                device.wait(
                    Until.hasObject(By.text(Pattern.compile("([A-Z][a-z]+[0-9]?\\.){4}[A-Z][a-z]+[0-9]?"))),
                    5000,
                )
            )
            assertTrue(device.findObject(By.text("复制")).parent.isEnabled)
            device.findObject(By.text("随机字符")).click()
            assertTrue(device.wait(Until.hasObject(By.desc("大写字母 A–Z")), 5000))
        } catch (failure: Throwable) {
            device.takeScreenshot(
                File(context.getExternalFilesDir(null), "legacy-utility-failure.png")
            )
            device.dumpWindowHierarchy(
                File(context.getExternalFilesDir(null), "legacy-utility-failure.xml")
            )
            throw failure
        } finally {
            scenario.close()
            repo.close()
            base.deleteRecursively()
            utilityBase.deleteRecursively()
        }
    }
}
