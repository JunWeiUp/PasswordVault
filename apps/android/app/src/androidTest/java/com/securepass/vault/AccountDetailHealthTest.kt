package com.securepass.vault

import android.content.ClipboardManager
import android.content.Intent
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.uiautomator.By
import androidx.test.uiautomator.UiDevice
import androidx.test.uiautomator.UiObject2
import androidx.test.uiautomator.Until
import java.io.File
import java.util.UUID
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

/**
 * Account detail: health banner + strength bar, "Generate new password" filling the editor through
 * "Use this password", and a real storage failure that keeps the draft and leaves the entry intact.
 */
@RunWith(AndroidJUnit4::class)
class AccountDetailHealthTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val context = instrumentation.targetContext
    private val device = UiDevice.getInstance(instrumentation)

    private fun dump(name: String) =
        device.dumpWindowHierarchy(File(context.getExternalFilesDir(null), "account-health-$name.xml"))

    private fun waitText(text: String, timeout: Long = 5_000): UiObject2 {
        val found = device.wait(Until.findObject(By.text(text)), timeout)
        if (found == null) dump(text.take(12))
        assertTrue("Expected text: $text", found != null)
        return found!!
    }

    private fun setDirectoriesWritable(root: File, writable: Boolean) {
        root.walkTopDown().filter { it.isDirectory }.forEach { assertTrue(it.setWritable(writable, false) || !writable) }
    }

    @Test
    fun healthBannerGeneratorAndSaveFailure() = runBlocking {
        val id = UUID.randomUUID().toString()
        val directory = File(context.cacheDir, "ui-test-$id")
        val fixture = VaultRepository(context, directory)
        while (!fixture.state.value.ready) delay(10)
        fixture.authenticate("1", true)
        // Fictional weak value: 8 characters, below the core audit threshold of 12.
        val weak = "w" + "eakpw12"
        assertTrue(fixture.save(VaultRepository.blank("password").put("title", "Health fixture").put("username", "qa@example.test").put("password", weak)))
        fixture.close()

        context.startActivity(
            Intent(context, MainActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK)
                .putExtra("uiTestVault", id),
        )
        assertTrue(device.wait(Until.hasObject(By.text("PasswordVault 已锁定")), 10_000))
        device.findObject(By.clazz("android.widget.EditText")).text = "1"
        device.findObject(By.desc("解锁")).click()
        assertTrue(device.wait(Until.hasObject(By.desc("账号")), 10_000))
        device.findObject(By.desc("账号")).click()
        waitText("Health fixture").click()

        // Detail: banner for the weak password and a strength bar.
        waitText("密码过弱")
        waitText("强度：弱")
        assertTrue(device.hasObject(By.desc("密码强度 1/4")))
        waitText("生成新密码").click()

        // Editor opens with the generator; "Use this password" fills the draft.
        waitText("使用这个密码").click()
        assertTrue("Generator closes", device.wait(Until.gone(By.text("使用这个密码")), 5_000))
        waitText("编辑账号")
        assertTrue("Generated password rates very strong", device.wait(Until.hasObject(By.text("强度：很强")), 5_000))
        device.findObject(By.text("保存")).click()
        assertTrue("Editor closes after save", device.wait(Until.gone(By.text("编辑账号")), 5_000))
        assertTrue("Banner disappears once the password is strong", device.wait(Until.gone(By.text("密码过弱")), 5_000))
        assertTrue(device.hasObject(By.text("强度：很强")))

        // Storage failure: the vault directory becomes read-only, so the encrypted commit fails.
        device.findObject(By.desc("编辑")).click()
        waitText("编辑账号")
        val title = device.findObjects(By.clazz("android.widget.EditText")).first { it.text == "Health fixture" }
        title.click()
        assertTrue(device.wait(Until.hasObject(By.focused(true).clazz("android.widget.EditText")), 3_000))
        device.findObject(By.focused(true).clazz("android.widget.EditText")).text = "Renamed fixture"
        assertTrue(device.wait(Until.hasObject(By.text("Renamed fixture")), 3_000))
        setDirectoriesWritable(directory, false)
        try {
            device.findObject(By.text("保存")).click()
            waitText("保存失败，输入已保留")
            assertTrue(device.hasObject(By.textContains("原条目没有被改动")))
            assertTrue("Draft kept", device.hasObject(By.text("Renamed fixture")))
            waitText("复制详情").click()
            device.waitForIdle()
            var details = ""
            instrumentation.runOnMainSync {
                details = context.getSystemService(ClipboardManager::class.java).primaryClip?.getItemAt(0)?.text?.toString().orEmpty()
            }
            assertTrue("Details name the error kind: $details", details.contains("error: Storage"))
            assertFalse("Details never contain field values", details.contains("Renamed") || details.contains("Health") || details.contains("qa@example.test"))

            // Discarding proves the original entry was not changed.
            device.findObject(By.desc("关闭")).click()
            waitText("放弃修改").click()
            assertTrue(device.wait(Until.gone(By.text("编辑账号")), 5_000))
            waitText("Health fixture")
            assertFalse(device.hasObject(By.text("Renamed fixture")))

            // Fail again, then restore storage and retry from the banner.
            device.findObject(By.desc("编辑")).click()
            waitText("编辑账号")
            device.findObjects(By.clazz("android.widget.EditText")).first { it.text == "Health fixture" }.click()
            assertTrue(device.wait(Until.hasObject(By.focused(true).clazz("android.widget.EditText")), 3_000))
            device.findObject(By.focused(true).clazz("android.widget.EditText")).text = "Renamed fixture"
            device.findObject(By.text("保存")).click()
            waitText("保存失败，输入已保留")
        } finally {
            setDirectoriesWritable(directory, true)
        }
        waitText("重试").click()
        assertTrue("Retry saves after storage recovers", device.wait(Until.gone(By.text("编辑账号")), 5_000))
        waitText("Renamed fixture")
        assertEquals(0, device.findObjects(By.text("保存失败，输入已保留")).size)
    }
}
