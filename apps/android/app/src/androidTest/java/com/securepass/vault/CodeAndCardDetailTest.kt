package com.securepass.vault

import android.content.Intent
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.uiautomator.By
import androidx.test.uiautomator.UiDevice
import androidx.test.uiautomator.UiScrollable
import androidx.test.uiautomator.UiSelector
import androidx.test.uiautomator.Until
import java.io.File
import java.util.UUID
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.json.JSONObject
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

/** The code setup QR needs confirmation; the card face shows only the masked number. */
@RunWith(AndroidJUnit4::class)
class CodeAndCardDetailTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val context = instrumentation.targetContext
    private val device = UiDevice.getInstance(instrumentation)

    private fun visible(text: String) = assertTrue("Missing $text", device.wait(Until.hasObject(By.text(text)), 10_000))

    @Test fun setupQrRequiresConfirmationAndCardFaceIsMasked() = runBlocking<Unit> {
        val id = UUID.randomUUID().toString()
        val dir = File(context.cacheDir, "ui-test-$id")
        val prefs = context.getSharedPreferences("ui", 0)
        val chinese = prefs.getBoolean("chinese", true)
        prefs.edit().putBoolean("chinese", true).commit()
        val vault = VaultRepository(context, dir)
        var scenario: ActivityScenario<MainActivity>? = null
        val number = "4" + "0".repeat(11) + "4321"
        try {
            withTimeout(10_000) { while (!vault.state.value.ready) delay(10) }
            vault.authenticate("1", true)
            assertTrue(vault.save(VaultRepository.blank("totp").put("title", "QR fixture").put("username", "qa@example.test").put("secret", "JBSWY3DPEHPK3PXP")))
            assertTrue(vault.save(VaultRepository.blank("creditCard").put("title", "Card fixture").put("card", JSONObject().put("number", number).put("cardholder", "FIXTURE HOLDER").put("expiryMonth", "07").put("expiryYear", "2030"))))
            vault.close()
            device.wakeUp()
            scenario = ActivityScenario.launch(
                Intent(context, MainActivity::class.java)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK)
                    .putExtra("uiTestVault", id),
            )
            unlockFromLockScreen(device)
            openDestination(device, "验证码")
            visible("QR fixture")
            // Tapping a code row copies the code; the trailing action opens details.
            device.findObject(By.desc("详情")).click()
            runCatching { UiScrollable(UiSelector().scrollable(true)).scrollIntoView(UiSelector().text("显示设置二维码")) }
            visible("显示设置二维码")
            device.findObject(By.text("显示设置二维码")).click()
            visible("显示设置二维码？")
            device.findObject(By.text("取消")).click()
            assertTrue(device.wait(Until.gone(By.text("显示设置二维码？")), 5_000))
            assertFalse("Cancel never renders the QR", device.hasObject(By.desc("设置二维码")))
            device.findObject(By.text("显示设置二维码")).click()
            visible("显示设置二维码？")
            device.findObject(By.text("显示")).click()
            assertTrue("QR shown after confirmation", device.wait(Until.hasObject(By.desc("设置二维码")), 5_000))
            device.findObject(By.text("完成")).click()
            assertTrue(device.wait(Until.gone(By.desc("设置二维码")), 5_000))
            backToNavigation(device)

            openDestination(device, "钱包")
            visible("Card fixture")
            device.findObject(By.text("Card fixture")).click()
            visible("•••• •••• •••• 4321")
            visible("有效期 07/30")
            visible("FIXTURE HOLDER")
            assertFalse("Full number is not on the card face", device.hasObject(By.text(number)))
        } catch (failure: Throwable) {
            device.dumpWindowHierarchy(File(context.getExternalFilesDir(null), "code-card-failure.xml"))
            throw failure
        } finally {
            scenario?.close()
            vault.close()
            dir.deleteRecursively()
            prefs.edit().putBoolean("chinese", chinese).commit()
        }
    }
}
