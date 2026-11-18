package com.securepass.vault

import android.content.Intent
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.uiautomator.By
import androidx.test.uiautomator.UiDevice
import androidx.test.uiautomator.Until
import java.util.UUID
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class VaultFlowTest {
    @Test
    fun createDeleteRestoreAndLock() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        val device = UiDevice.getInstance(instrumentation)
        val intent =
            Intent(context, MainActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK)
                .putExtra("uiTestVault", UUID.randomUUID().toString())
                .putExtra("qaScreenshots", true)
        context.startActivity(intent)
        createVaultFromWelcome(device)
        val title = "Android UI note"
        createNote(device, title)
        device.takeScreenshot(java.io.File(context.getExternalFilesDir(null), "qa-notes.png"))
        moveToTrash(device, title)
        openTrash(device)
        assertTrue("Trash must show the deleted note", device.wait(Until.hasObject(By.text(title)), 5_000))
        device.findObject(By.text(title)).click()
        assertTrue(device.wait(Until.hasObject(By.text("恢复")), 5_000))
        device.findObject(By.text("恢复")).click()
        assertTrue(device.wait(Until.gone(By.text("恢复")), 5_000))
        backToNavigation(device)
        device.findObject(By.desc("笔记")).click()
        assertTrue(device.wait(Until.hasObject(By.text(title)), 5_000))
        device.findObject(By.desc("锁定")).click()
        assertTrue(device.wait(Until.hasObject(By.text("PasswordVault 已锁定")), 5_000))
    }
}
