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
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class BackgroundSessionTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val context = instrumentation.targetContext

    @Test
    fun backgroundReturnHonorsOriginalIdleDeadlineAndManualLock() = runBlocking {
        val dir = File(context.cacheDir, "background-${UUID.randomUUID()}")
        var now = 0L
        val vault = VaultRepository(context, dir) { now }
        try {
            withTimeout(10_000) { while (!vault.state.value.ready) delay(10) }
            vault.authenticate("Fixture background", true)
            assertTrue(
                vault.mutate(
                    "settings",
                    JSONObject().put("settings", JSONObject().put("autoLockMinutes", 1)),
                )
            )
            now = 30_000
            vault.background().join()
            assertTrue(vault.state.value.unlocked)
            now = 59_999
            vault.foreground()
            assertTrue(vault.state.value.unlocked)
            now = 60_000
            vault.foreground()
            assertFalse(vault.state.value.unlocked)
            vault.authenticate("Fixture background", false)
            assertTrue(vault.state.value.unlocked)
            val biometricKey = vault.biometricKey()
            vault.lock()
            now = 180_000
            vault.unlockBiometric(biometricKey)
            vault.checkIdle()
            assertTrue(vault.state.value.unlocked)
            assertTrue(biometricKey.all { it == 0.toByte() })
            vault.lock()
            vault.background().join()
            vault.foreground()
            assertFalse(vault.state.value.unlocked)
        } finally {
            vault.close()
            dir.deleteRecursively()
        }
    }

    @Test
    fun backgroundCheckpointIsEncryptedRecoversAfterRestartAndDiscardWins() = runBlocking {
        val dir = File(context.cacheDir, "background-draft-${UUID.randomUUID()}")
        var vault = VaultRepository(context, dir)
        try {
            withTimeout(10_000) { while (!vault.state.value.ready) delay(10) }
            vault.authenticate("Fixture draft", true)
            val draft = VaultRepository.blank("secureNote").put("title", "BACKGROUND_DRAFT_CANARY")
            vault.pendingDraft = draft.toString()
            vault.background().join()
            assertTrue(vault.state.value.unlocked)
            assertEquals(draft.toString(), vault.pendingDraft)
            assertTrue(File(dir, "mobile-draft.sealed").isFile)
            dir.walkTopDown()
                .filter { it.isFile }
                .forEach {
                    assertFalse(
                        it.readBytes()
                            .toString(Charsets.ISO_8859_1)
                            .contains("BACKGROUND_DRAFT_CANARY")
                    )
                }
            vault.close()
            vault = VaultRepository(context, dir)
            withTimeout(10_000) { while (!vault.state.value.ready) delay(10) }
            assertFalse(vault.state.value.unlocked)
            vault.authenticate("Fixture draft", false)
            assertEquals(
                "BACKGROUND_DRAFT_CANARY",
                JSONObject(vault.state.value.recoveredDraft!!).getString("title"),
            )
            val checkpoint = vault.background()
            vault.discardDraft()
            checkpoint.join()
            assertFalse(File(dir, "mobile-draft.sealed").exists())
            vault.lock()
            vault.authenticate("Fixture draft", false)
            assertNull(vault.pendingDraft)
        } finally {
            vault.close()
            dir.deleteRecursively()
        }
    }

    @Test
    fun homeAndScreenOffUseDifferentLockPolicies() = runBlocking {
        val id = UUID.randomUUID().toString()
        val dir = File(context.cacheDir, "ui-test-$id")
        val prefs = context.getSharedPreferences("ui", 0)
        val prior = prefs.getBoolean("chinese", true)
        prefs.edit().putBoolean("chinese", true).commit()
        val device = UiDevice.getInstance(instrumentation)
        val intent =
            Intent(context, MainActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                .putExtra("uiTestVault", id)
                .putExtra("qaScreenshots", true)
        var scenario: ActivityScenario<MainActivity>? = null
        try {
            device.wakeUp()
            device.executeShellCommand("wm dismiss-keyguard")
            scenario = ActivityScenario.launch(intent)
            assertTrue(device.wait(Until.hasObject(By.text("创建本机加密资料库")), 10_000))
            device.findObjects(By.clazz("android.widget.EditText"))[0].text = "1"
            device.findObjects(By.clazz("android.widget.EditText"))[1].text = "1"
            device.wait(Until.findObject(By.text("创建资料库").enabled(true)), 5_000).click()
            assertTrue(device.wait(Until.hasObject(By.desc("笔记")), 10_000))
            device.pressHome()
            withTimeout(5_000) {
                while (scenario!!.state != androidx.lifecycle.Lifecycle.State.CREATED) delay(20)
            }
            context.startActivity(
                Intent(intent)
                    .setFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
            )
            assertTrue(device.wait(Until.hasObject(By.desc("笔记")), 10_000))
            assertFalse(device.hasObject(By.text("解锁资料库")))
            scenario.recreate()
            assertTrue(device.wait(Until.hasObject(By.desc("笔记")), 10_000))
            device.pressHome()
            withTimeout(5_000) {
                while (scenario!!.state != androidx.lifecycle.Lifecycle.State.CREATED) delay(20)
            }
            device.sleep()
            delay(800)
            device.wakeUp()
            device.executeShellCommand("wm dismiss-keyguard")
            context.startActivity(
                Intent(intent)
                    .setFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
            )
            assertTrue(device.wait(Until.hasObject(By.text("解锁资料库")), 10_000))
        } catch (failure: Throwable) {
            device.dumpWindowHierarchy(
                File(context.getExternalFilesDir(null), "qa-background-failure.xml")
            )
            throw failure
        } finally {
            device.wakeUp()
            device.executeShellCommand("wm dismiss-keyguard")
            scenario?.close()
            prefs.edit().putBoolean("chinese", prior).commit()
            dir.deleteRecursively()
        }
    }
}
