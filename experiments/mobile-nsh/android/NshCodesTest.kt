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
import java.util.regex.Pattern
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

/** The codes list is the shared NSH page embedded in the Android app (pilot). */
@RunWith(AndroidJUnit4::class)
class NshCodesTest {
    @Test fun nshCodesPageShowsLiveCodesFromTheVault() = runBlocking<Unit> {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        val device = UiDevice.getInstance(instrumentation)
        val id = UUID.randomUUID().toString()
        val directory = File(context.cacheDir, "ui-test-$id")
        var scenario: ActivityScenario<MainActivity>? = null
        try {
            val fixture = VaultRepository(context, directory)
            withTimeout(15_000) { while (!fixture.state.value.ready) delay(10) }
            fixture.authenticate("1", true)
            assertTrue(fixture.save(VaultRepository.blank("totp").put("title", "NSH Example").put("username", "nsh@example.test")
                .put("secret", "JBSWY3DPEHPK3PXP").put("period", 30)))
            fixture.close()
            device.wakeUp()
            device.executeShellCommand("wm dismiss-keyguard")
            scenario = ActivityScenario.launch(
                Intent(context, MainActivity::class.java)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK)
                    .putExtra("uiTestVault", id),
            )
            assertTrue(device.wait(Until.hasObject(By.text("PasswordVault 已锁定")), 15_000))
            device.findObjects(By.clazz("android.widget.EditText")).first().text = "1"
            device.findObject(By.desc("解锁")).click()
            assertTrue(device.wait(Until.hasObject(By.desc("验证码")), 15_000))
            device.findObject(By.desc("验证码")).click()
            // Rendered by NSH as native Android views, fed by the host bridge.
            assertTrue("NSH title", device.wait(Until.hasObject(By.text("NSH Example")), 15_000))
            val out = context.getExternalFilesDir(null) ?: error("no output directory")
            Thread.sleep(2_000)
            device.takeScreenshot(File(out, "nsh-codes.png"))
            device.dumpWindowHierarchy(File(out, "nsh-codes.xml"))
            assertTrue("live code", device.wait(Until.hasObject(By.text(Pattern.compile("\\d{3} \\d{3}"))), 10_000))
        } finally {
            scenario?.close()
            directory.deleteRecursively()
        }
    }
}
