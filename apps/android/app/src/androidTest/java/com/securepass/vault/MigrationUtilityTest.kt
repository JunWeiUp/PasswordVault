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
            val parsed = repo.command("parse-totp", JSONObject().put("uri", uri))
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
                            repo.command("generate", options.request()).getString("password")
                        )
                    )
                }
            assertFalse(GeneratorOptions(4, false, false, false, false).enabled)
        } finally {
            repo.close()
            base.deleteRecursively()
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
                                PasswordGeneratorControls(repo) { zh, _ -> zh }
                            }
                    }
                }
            }
            assertTrue(device.wait(Until.hasObject(By.text("扫描验证码")), 8000))
            assertTrue(device.wait(Until.hasObject(By.text("正在扫描")), 10000))
            assertFalse(device.hasObject(By.textContains("相机暂不可用")))
            device.takeScreenshot(File(context.getExternalFilesDir(null), "legacy-live-camera.png"))
            device.findObject(By.text("关闭")).click()
            assertTrue(device.wait(Until.hasObject(By.desc("大写字母")), 5000))
            for (label in listOf("大写字母", "小写字母", "数字", "符号")) device
                .findObject(By.desc(label))
                .click()
            assertTrue(device.wait(Until.hasObject(By.text("请至少选择一种字符类型")), 5000))
            assertFalse(device.findObject(By.text("重新生成")).parent.isEnabled)
            assertFalse(device.findObject(By.text("复制")).parent.isEnabled)
            device.takeScreenshot(
                File(context.getExternalFilesDir(null), "legacy-generator-disabled.png")
            )
            device.findObject(By.desc("数字")).click()
            assertTrue(device.wait(Until.gone(By.text("请至少选择一种字符类型")), 5000))
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
