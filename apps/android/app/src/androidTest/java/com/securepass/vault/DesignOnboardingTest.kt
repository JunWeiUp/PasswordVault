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
import kotlinx.coroutines.*
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class DesignOnboardingTest {
    @Test fun onboardingRequiresMatchingPasswordsAndReachesRealBiometricChoice() = runBlocking<Unit> {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        val id = UUID.randomUUID().toString()
        val directory = File(context.cacheDir, "ui-test-$id")
        val preferences = context.getSharedPreferences("ui", 0)
        val chinese = preferences.getBoolean("chinese", true)
        preferences.edit().putBoolean("chinese", true).commit()
        var scenario: ActivityScenario<MainActivity>? = null
        val device = UiDevice.getInstance(instrumentation)
        fun text(label: String) = device.wait(Until.findObject(By.text(label)), 8_000).also { assertNotNull("Missing $label", it) }
        fun shot(name: String) { device.waitForIdle(); Thread.sleep(300); device.takeScreenshot(File(context.getExternalFilesDir(null), "align-$name.png")) }
        try {
            val fixture = VaultRepository(context, directory)
            withTimeout(10_000) { while (!fixture.state.value.ready) delay(10) }
            assertFalse(fixture.state.value.exists)
            fixture.close()
            device.wakeUp(); device.executeShellCommand("wm dismiss-keyguard")
            scenario = ActivityScenario.launch(Intent(context, MainActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK)
                .putExtra("uiTestVault", id).putExtra("qaScreenshots", true))
            text("欢迎使用 PasswordVault"); shot("onb0")
            text("新建密码库").click(); text("设置主密码"); shot("onb1")
            var fields = device.findObjects(By.clazz("android.widget.EditText"))
            fields[0].text = "1"; fields[1].text = "2"
            device.waitForIdle(); Thread.sleep(200)
            var submit = text("继续")!!
            while (!submit.isClickable && submit.parent != null) submit = submit.parent
            assertFalse("Mismatched passwords must not submit", submit.isEnabled)
            fields = device.findObjects(By.clazz("android.widget.EditText")); fields[1].text = "1"
            device.waitForIdle()
            Thread.sleep(200)
            val continueBounds = text("继续").visibleBounds
            assertTrue(continueBounds.height() > 0)
            device.click(continueBounds.centerX(), continueBounds.centerY())
            text("以后再说"); shot("onb2")
            text("以后再说").click()
            assertTrue(device.wait(Until.hasObject(By.desc("笔记")), 10_000))
        } catch (failure: Throwable) {
            shot("onboarding-failure")
            device.dumpWindowHierarchy(File(context.getExternalFilesDir(null), "align-onboarding-failure.xml"))
            throw failure
        } finally {
            scenario?.close(); directory.deleteRecursively()
            preferences.edit().putBoolean("chinese", chinese).commit()
        }
    }
}
