package com.securepass.vault

import android.content.Intent
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.uiautomator.By
import androidx.test.uiautomator.UiDevice
import androidx.test.uiautomator.Until
import java.util.UUID
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

/** Moving to Trash can be undone from the snackbar, and Trash can be emptied after confirmation. */
@RunWith(AndroidJUnit4::class)
class TrashUndoTest {
    @Test fun undoRestoresAndEmptyTrashDeletesPermanently() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        val device = UiDevice.getInstance(instrumentation)
        context.startActivity(
            Intent(context, MainActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK)
                .putExtra("uiTestVault", UUID.randomUUID().toString()),
        )
        createVaultFromWelcome(device)
        val title = "Undo fixture note"
        createNote(device, title)

        moveToTrash(device, title)
        assertTrue("Undo snackbar", device.wait(Until.hasObject(By.text("撤销")), 5_000))
        device.findObject(By.text("撤销")).click()
        assertTrue("Undo restores the note", device.wait(Until.hasObject(By.text(title)), 5_000))

        moveToTrash(device, title)
        openTrash(device)
        assertTrue(device.wait(Until.hasObject(By.text(title)), 5_000))
        device.findObject(By.text("清空回收站…")).click()
        assertTrue(device.wait(Until.hasObject(By.text("清空回收站？")), 5_000))
        assertTrue(device.hasObject(By.textContains("将永久删除 1 个项目")))
        device.findObject(By.text("永久删除")).click()
        assertTrue("Trash is empty", device.wait(Until.hasObject(By.text("回收站是空的")), 5_000))
    }
}
