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

/** End-to-end navigation uses only a UUID-isolated synthetic encrypted vault. */
@RunWith(AndroidJUnit4::class)
class WorkspaceNavigationTest {
    @Test fun notesFirstDrawerWalletDetailsAndSettingsBackStack() = runBlocking {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        val id = UUID.randomUUID().toString()
        val dir = File(context.cacheDir, "ui-test-$id")
        val prefs = context.getSharedPreferences("ui", 0)
        val chinese = prefs.getBoolean("chinese", true)
        prefs.edit().putBoolean("chinese", true).commit()
        val vault = VaultRepository(context, dir)
        val device = UiDevice.getInstance(instrumentation)
        var scenario: ActivityScenario<MainActivity>? = null
        fun visible(text: String) = assertTrue("Missing $text", device.wait(Until.hasObject(By.text(text)), 10_000))
        fun clickDescription(label: String) {
            val node = device.wait(Until.findObject(By.desc(label)), 5_000)
            assertNotNull("Missing action $label", node)
            node.click()
        }
        fun shot(name: String) {
            device.takeScreenshot(File(context.getExternalFilesDir(null), "workspace-$name.png"))
        }
        try {
            withTimeout(10_000) { while (!vault.state.value.ready) delay(10) }
            vault.authenticate("1", true)
            val theme = InstrumentationRegistry.getArguments().getString("designTheme") ?: "light"
            assertTrue(vault.mutate(CoreRequest.settings(JSONObject().put("theme", theme))))
            for ((type, title) in listOf("secureNote" to "Navigation note", "password" to "Navigation account", "creditCard" to "Navigation card", "identity" to "Navigation identity")) {
                val record = VaultRepository.blank(type).put("title", title).put("isFavorite", true)
                if (type == "secureNote") record.put("note", "Synthetic navigation fixture")
                if (type == "password") record.put("username", "fixture@example.test").put("password", "Fixture password only")
                assertTrue(vault.save(record))
            }
            vault.close()
            device.wakeUp()
            device.executeShellCommand("wm dismiss-keyguard")
            scenario = ActivityScenario.launch(
                Intent(context, MainActivity::class.java)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK)
                    .putExtra("uiTestVault", id).putExtra("qaScreenshots", true)
            )
            visible("PasswordVault 已锁定")
            device.findObjects(By.clazz("android.widget.EditText"))[0].text = "1"
            device.findObject(By.desc("解锁")).click()
            visible("Navigation note")
            assertFalse(device.hasObject(By.text("Navigation account")))
            shot("notes")
            clickDescription("账号")
            visible("Navigation account")
            assertFalse(device.hasObject(By.text("Navigation card")))
            device.findObject(By.text("Navigation account")).click()
            visible("fixture@example.test")
            assertFalse("Details must hide root navigation", device.hasObject(By.desc("笔记")))
            shot("account")
            clickDescription("编辑")
            visible("编辑账号")
            val fields = device.findObjects(By.clazz("android.widget.EditText"))
            assertTrue(fields.isNotEmpty())
            fields[0].text = "Navigation edited"
            device.findObject(By.text("保存")).click()
            visible("Navigation edited")
            visible("fixture@example.test")
            device.pressBack()
            clickDescription("钱包")
            visible("Navigation card")
            visible("Navigation identity")
            assertFalse(device.hasObject(By.text("Navigation edited")))
            shot("wallets")
            clickDescription("打开导航")
            device.waitForIdle()
            delay(1_000) // Wait for the Material drawer's entrance before using its screen coordinates.
            visible("全部项目")
            device.findObject(By.text("个人收藏")).parent.click()
            assertTrue("Drawer should close after choosing Favorites", device.wait(Until.gone(By.text("全部项目")), 5_000))
            visible("Navigation edited")
            visible("Navigation card")
            shot("favorites")
            device.findObject(By.text("Navigation edited")).click()
            visible("fixture@example.test")
            device.pressBack()
            visible("个人收藏")
            visible("Navigation edited")
            device.pressBack()
            clickDescription("设置")
            visible("通用")
            shot("settings")
            device.findObject(By.text("安全")).click()
            visible("修改主密码")
            shot("security")
            device.pressBack()
            visible("通用")
            assertFalse(device.hasObject(By.text("修改主密码")))
            clickDescription("笔记")
            visible("Navigation note")
            clickDescription("锁定")
            visible("PasswordVault 已锁定")
        } catch (failure: Throwable) {
            shot("failure")
            device.dumpWindowHierarchy(File(context.getExternalFilesDir(null), "workspace-failure.xml"))
            throw failure
        } finally {
            scenario?.close()
            vault.close()
            dir.deleteRecursively()
            prefs.edit().putBoolean("chinese", chinese).commit()
        }
    }
    @Test fun deviceSecretsHideAgainAfterBackgroundAndMissingFilesFailClosed() = runBlocking<Unit> {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        val id = UUID.randomUUID().toString()
        val dir = File(context.cacheDir, "ui-test-$id")
        val prefs = context.getSharedPreferences("ui", 0)
        val chinese = prefs.getBoolean("chinese", true)
        prefs.edit().putBoolean("chinese", true).commit()
        val vault = VaultRepository(context, dir)
        val device = UiDevice.getInstance(instrumentation)
        var scenario: ActivityScenario<MainActivity>? = null
        val intent = Intent(context, MainActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK)
            .putExtra("uiTestVault", id).putExtra("qaScreenshots", true)
        try {
            withTimeout(10_000) { while (!vault.state.value.ready) delay(10) }
            vault.authenticate("1", true)
            vault.command(CoreRequest.devicesEnable(true, "1"))
            val payload = JSONObject()
                .put("version", 1).put("host", "fixture.example.test").put("port", 22)
                .put("username", "fixture").put("authMethod", "password")
                .put("password", "DEVICE_DISPLAY_CANARY").put("privateKey", "").put("notes", "")
                .put("aliases", org.json.JSONArray()).put("services", org.json.JSONArray())
                .put("commands", org.json.JSONArray().put(JSONObject().put("id", "fixture-command").put("title", "Fixture document").put("text", "INERT_DOCUMENT_CANARY").put("secret", true)))
                .put("files", org.json.JSONArray())
            val entry = VaultRepository.blank("device").put("title", "Navigation device").put("device", payload)
            assertTrue(vault.save(entry))
            try {
                vault.command(CoreRequest.devicesFileRead(entry.getString("id"), "missing-fixture-file"))
                fail("Missing file must never return a document")
            } catch (_: Exception) { }
            vault.close()
            scenario = ActivityScenario.launch(intent)
            assertTrue(device.wait(Until.hasObject(By.text("PasswordVault 已锁定")), 10_000))
            device.findObjects(By.clazz("android.widget.EditText"))[0].text = "1"
            device.findObject(By.desc("解锁")).click()
            device.wait(Until.findObject(By.desc("打开导航")), 10_000).click()
            device.waitForIdle()
            delay(1_000)
            device.wait(Until.findObject(By.text("设备与服务")), 5_000).parent.click()
            assertTrue("Drawer should close after choosing Devices", device.wait(Until.gone(By.text("全部项目")), 5_000))
            val deviceEntry = device.wait(Until.findObject(By.text("Navigation device")), 10_000)
            assertNotNull("Saved device must be listed", deviceEntry)
            deviceEntry.click()
            assertTrue(device.wait(Until.hasObject(By.text("fixture.example.test")), 5_000))
            assertFalse(device.hasObject(By.text("DEVICE_DISPLAY_CANARY")))
            // Personal format-7 devices can be edited on the phone (the core validates the save).
            assertTrue(device.hasObject(By.desc("编辑")))
            // The connection section may be below the fold on small displays.
            var attempts = 0
            while (!device.hasObject(By.desc("显示密码")) && attempts++ < 4) {
                device.swipe(device.displayWidth / 2, device.displayHeight * 3 / 4, device.displayWidth / 2, device.displayHeight / 3, 25)
            }
            device.findObject(By.desc("显示密码")).click()
            assertTrue(device.wait(Until.hasObject(By.text("DEVICE_DISPLAY_CANARY")), 5_000))
            device.pressHome()
            withTimeout(5_000) { while (scenario!!.state != androidx.lifecycle.Lifecycle.State.CREATED) delay(20) }
            context.startActivity(Intent(intent).setFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP))
            assertTrue(device.wait(Until.hasObject(By.text("fixture.example.test")), 5_000))
            assertFalse(device.hasObject(By.text("DEVICE_DISPLAY_CANARY")))
            assertFalse(device.hasObject(By.text("INERT_DOCUMENT_CANARY")))
            device.takeScreenshot(File(context.getExternalFilesDir(null), "workspace-device.png"))
        } catch (failure: Throwable) {
            device.takeScreenshot(File(context.getExternalFilesDir(null), "workspace-device-failure.png"))
            device.dumpWindowHierarchy(File(context.getExternalFilesDir(null), "workspace-device-failure.xml"))
            throw failure
        } finally {
            scenario?.close(); vault.close(); dir.deleteRecursively()
            prefs.edit().putBoolean("chinese", chinese).commit()
        }
    }

}
