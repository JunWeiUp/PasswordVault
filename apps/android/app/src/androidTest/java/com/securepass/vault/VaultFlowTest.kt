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
        assertTrue(device.wait(Until.hasObject(By.text("创建本机加密资料库")), 10_000))
        val inputs = device.findObjects(By.clazz("android.widget.EditText"))
        inputs[0].text = "1"
        inputs[1].text = "1"
        device.findObject(By.text("创建资料库")).click()
        assertTrue(device.wait(Until.hasObject(By.desc("笔记")), 10_000))
        device.findObject(By.desc("笔记")).click()
        assertTrue(device.wait(Until.hasObject(By.desc("新建")), 5_000))
        device.findObject(By.desc("新建")).click()
        assertTrue(device.wait(Until.hasObject(By.text("编辑笔记")), 5_000))
        device.findObjects(By.clazz("android.widget.EditText"))[0].text = "Android UI note"
        device.findObject(By.text("保存")).click()
        assertTrue(device.wait(Until.hasObject(By.text("Android UI note")), 5_000))
        device.takeScreenshot(java.io.File(context.getExternalFilesDir(null), "qa-notes.png"))
        device.findObject(By.desc("更多")).click()
        device.findObject(By.text("删除…")).click()
        assertTrue(device.wait(Until.hasObject(By.text("移到回收站？")), 5_000))
        device.findObject(By.text("删除")).click()
        assertTrue(device.wait(Until.gone(By.text("移到回收站？")), 5_000))
        device.findObject(By.desc("设置")).click()
        assertTrue(device.wait(Until.hasObject(By.text("安全")), 5_000))
        device.dumpWindowHierarchy(
            java.io.File(context.getExternalFilesDir(null), "qa-settings-start.xml")
        )
        repeat(12) {
            if (android.os.Build.VERSION.SDK_INT >= 33) instrumentation.uiAutomation.clearCache()
            val target = device.findObject(By.text("回收站"))
            val targetBounds = runCatching { target?.visibleBounds }.getOrNull()
            if (
                targetBounds == null ||
                    targetBounds.height() == 0 ||
                    targetBounds.centerY() > device.displayHeight * 0.72
            ) {
                val bounds = device.findObject(By.scrollable(true)).visibleBounds
                device.swipe(
                    bounds.centerX(),
                    bounds.bottom - 100,
                    bounds.centerX(),
                    bounds.centerY(),
                    100,
                )
                android.os.SystemClock.sleep(350)
            }
        }
        device.dumpWindowHierarchy(java.io.File(context.getExternalFilesDir(null), "qa-trash.xml"))
        device.takeScreenshot(java.io.File(context.getExternalFilesDir(null), "qa-trash.png"))
        android.os.SystemClock.sleep(500)
        if (android.os.Build.VERSION.SDK_INT >= 33) instrumentation.uiAutomation.clearCache()
        // Resolve immediately at click time; cached nodes may be replaced by Compose scrolling.
        device.findObject(androidx.test.uiautomator.UiSelector().text("回收站")).click()
        val enteredTrash = device.wait(Until.hasObject(By.text("Android UI note")), 5_000)
        if (!enteredTrash) {
            device.dumpWindowHierarchy(
                java.io.File(context.getExternalFilesDir(null), "qa-trash.xml")
            )
            device.takeScreenshot(java.io.File(context.getExternalFilesDir(null), "qa-trash.png"))
        }
        assertTrue("Trash must show the deleted note", enteredTrash)
        device.findObject(By.text("Android UI note")).click()
        assertTrue(device.wait(Until.hasObject(By.text("恢复")), 5_000))
        device.findObject(By.text("恢复")).click()
        device.findObject(By.desc("笔记")).click()
        assertTrue(device.wait(Until.hasObject(By.text("Android UI note")), 5_000))
        device.findObject(By.desc("锁定")).click()
        assertTrue(device.wait(Until.hasObject(By.text("解锁资料库")), 5_000))
    }
}
