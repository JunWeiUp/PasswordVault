package com.securepass.vault

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
import kotlinx.coroutines.withTimeout
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

/** Format-7 device create/edit on the phone: validation, preserved fields, save failure and retry. */
@RunWith(AndroidJUnit4::class)
class DeviceEditorTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val context = instrumentation.targetContext
    private val device = UiDevice.getInstance(instrumentation)

    private fun waitText(text: String, timeout: Long = 5_000): UiObject2 {
        val found = device.wait(Until.findObject(By.text(text)), timeout)
        if (found == null) device.dumpWindowHierarchy(File(context.getExternalFilesDir(null), "device-editor-${text.take(10)}.xml"))
        assertNotNull("Expected text: $text", found)
        return found!!
    }

    private fun setField(index: Int, value: String) {
        assertTrue(device.wait(Until.hasObject(By.clazz("android.widget.EditText")), 5_000))
        device.findObjects(By.clazz("android.widget.EditText"))[index].click()
        assertTrue(device.wait(Until.hasObject(By.focused(true).clazz("android.widget.EditText")), 3_000))
        device.findObject(By.focused(true).clazz("android.widget.EditText")).text = value
        device.waitForIdle()
    }

    private fun saveEnabled() = device.findObject(By.text("保存")).parent?.isEnabled ?: device.findObject(By.text("保存")).isEnabled

    private fun openDrawerItem(label: String, done: () -> Boolean) {
        repeat(5) {
            if (done()) return
            if (!device.hasObject(By.text(label))) {
                device.wait(Until.hasObject(By.desc("打开导航")), 3_000)
                runCatching { device.findObject(By.desc("打开导航"))?.click() }
                device.wait(Until.hasObject(By.text(label)), 2_000)
            }
            android.os.SystemClock.sleep(400)
            runCatching { device.findObject(By.text(label))?.click() }
            device.wait(Until.hasObject(By.text("Build host")), 2_000)
        }
        assertTrue("Drawer destination $label", done())
    }

    private fun storedDevice(): JSONObject = JSONObject()
        .put("id", "device-editor-fixture").put("type", "device").put("title", "Build host").put("username", "")
        .put("note", "").put("tags", JSONArray()).put("noteFormat", "plain").put("isDeleted", false)
        .put("futureTopLevel", "keep-top")
        .put("device", JSONObject()
            .put("version", 1).put("host", "build.example.test").put("port", 2222).put("username", "deploy")
            .put("authMethod", "password").put("password", "").put("privateKey", "")
            .put("aliases", JSONArray(listOf("builder-alias"))).put("notes", "")
            .put("services", JSONArray().put(JSONObject().put("id", "s1").put("name", "VNC desk").put("kind", "vnc").put("remotePort", 5900).put("localPort", 5901).put("path", "")))
            .put("commands", JSONArray().put(JSONObject().put("id", "c1").put("title", "deploy.sh").put("text", "echo synthetic").put("secret", true)))
            .put("files", JSONArray())
            .put("futureDeviceField", "keep-device"))

    @Test
    fun createEditValidateAndPreserveDeviceFields() = runBlocking<Unit> {
        val id = UUID.randomUUID().toString()
        val directory = File(context.cacheDir, "ui-test-$id")
        val fixture = VaultRepository(context, directory)
        try {
            withTimeout(15_000) { while (!fixture.state.value.ready) delay(25) }
            fixture.authenticate("1", true)
            // Below format 7 the core refuses device records outright.
            assertFalse(fixture.save(storedDevice()))
            fixture.command("devices-enable", JSONObject().put("confirm", true).put("currentPassword", "1"))
            // The core validates device payloads: an invalid port is rejected and nothing is written.
            assertFalse(fixture.save(storedDevice().apply { getJSONObject("device").put("port", 0) }))
            assertFalse(fixture.save(storedDevice().put("sharedVaultId", "shared-x")))
            assertTrue(fixture.state.value.entries.none { it.optString("type") == "device" })
            assertTrue(fixture.save(storedDevice()))
        } finally { fixture.close() }

        context.startActivity(
            Intent(context, MainActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK)
                .putExtra("uiTestVault", id),
        )
        assertTrue(device.wait(Until.hasObject(By.text("PasswordVault 已锁定")), 10_000))
        device.findObject(By.clazz("android.widget.EditText")).text = "1"
        device.findObject(By.desc("解锁")).click()
        assertTrue(device.wait(Until.hasObject(By.desc("笔记")), 10_000))
        openDrawerItem("设备与服务") { device.hasObject(By.text("Build host")) }

        // Edit: invalid host and port are rejected before saving.
        waitText("Build host").click()
        assertTrue(device.wait(Until.hasObject(By.desc("编辑")), 5_000))
        device.findObject(By.desc("编辑")).click()
        waitText("编辑设备")
        setField(1, "bad host;id")
        assertTrue(device.wait(Until.hasObject(By.textContains("主机只能包含")), 3_000))
        assertFalse("Save disabled for an invalid host", saveEnabled())
        setField(1, "10.0.0.7")
        assertTrue(device.wait(Until.gone(By.textContains("主机只能包含")), 3_000))
        setField(2, "70000")
        assertTrue(device.wait(Until.hasObject(By.text("端口需为 1–65535。")), 3_000))
        assertFalse("Save disabled for an invalid port", saveEnabled())
        setField(2, "22")
        assertTrue(device.wait(Until.gone(By.text("端口需为 1–65535。")), 3_000))
        device.findObject(By.text("保存")).click()
        assertTrue("Editor closes", device.wait(Until.gone(By.text("编辑设备")), 5_000))
        waitText("10.0.0.7")
        assertTrue("Aliases kept", device.hasObject(By.textContains("builder-alias")))

        // Save failure keeps the input; retry succeeds once storage is writable again.
        device.findObject(By.desc("编辑")).click()
        waitText("编辑设备")
        setField(3, "ops-user")
        val dirs = directory.walkTopDown().filter { it.isDirectory }.toList()
        dirs.forEach { it.setWritable(false, false) }
        try {
            device.findObject(By.text("保存")).click()
            waitText("保存失败，输入已保留")
            assertTrue(device.hasObject(By.textContains("原条目没有被改动")))
            // The retry below saves "ops-user", proving the draft survived the failure.
        } finally { dirs.forEach { it.setWritable(true, false) } }
        waitText("重试").click()
        assertTrue(device.wait(Until.gone(By.text("编辑设备")), 5_000))
        waitText("ops-user")

        // Create a new device from the Devices page.
        device.pressBack()
        assertTrue(device.wait(Until.hasObject(By.text("新建")), 5_000))
        device.findObject(By.text("新建")).click()
        waitText("新建设备")
        setField(0, "Lab NAS")
        setField(1, "nas.example.test")
        device.findObject(By.text("保存")).click()
        assertTrue(device.wait(Until.gone(By.text("新建设备")), 5_000))
        waitText("Lab NAS")

        // Read the stored records from the app's own (QA) repository: unknown and untouched fields survive.
        var appVault: VaultRepository? = null
        instrumentation.runOnMainSync {
            val activity = androidx.test.runner.lifecycle.ActivityLifecycleMonitorRegistry.getInstance()
                .getActivitiesInStage(androidx.test.runner.lifecycle.Stage.RESUMED).filterIsInstance<MainActivity>().first()
            appVault = MainActivity::class.java.getDeclaredField("vault").apply { isAccessible = true }.get(activity) as VaultRepository
        }
        val reader = appVault!!
        reader.refresh()
        run {
            val edited = reader.state.value.entries.first { it.optString("id") == "device-editor-fixture" }
            val data = edited.getJSONObject("device")
            assertEquals("10.0.0.7", data.getString("host"))
            assertEquals(22, data.getInt("port"))
            assertEquals("ops-user", data.getString("username"))
            assertEquals("keep-device", data.getString("futureDeviceField"))
            assertEquals("keep-top", edited.getString("futureTopLevel"))
            assertEquals(storedDevice().getJSONObject("device").getJSONArray("aliases").toString(), data.getJSONArray("aliases").toString())
            assertEquals("VNC desk", data.getJSONArray("services").getJSONObject(0).getString("name"))
            assertEquals("echo synthetic", data.getJSONArray("commands").getJSONObject(0).getString("text"))
            val created = reader.state.value.entries.first { it.optString("title") == "Lab NAS" }
            assertEquals("nas.example.test", created.getJSONObject("device").getString("host"))
            assertEquals(1, created.getJSONObject("device").getInt("version"))
        }
    }
}
