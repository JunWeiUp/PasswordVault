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
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

/** Identity documents are edited through the shared `document.*` custom fields and keep other fields. */
@RunWith(AndroidJUnit4::class)
class IdentityDocumentEditTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val context = instrumentation.targetContext
    private val device = UiDevice.getInstance(instrumentation)

    private fun visible(text: String) = assertTrue("Missing $text", device.wait(Until.hasObject(By.text(text)), 10_000))

    private fun type(label: String, value: String) {
        runCatching { UiScrollable(UiSelector().scrollable(true)).scrollIntoView(UiSelector().description(label)) }
        val field = device.wait(Until.findObject(By.desc(label)), 5_000)
        assertNotNull("Field $label", field)
        field.click()
        val focused = device.wait(Until.findObject(By.focused(true).clazz("android.widget.EditText")), 3_000)
        assertNotNull("Focused $label", focused)
        focused.text = value
    }

    private fun openEditor() {
        repeat(3) {
            if (device.hasObject(By.text("编辑钱包 · 证件"))) return
            device.wait(Until.findObject(By.desc("编辑")), 5_000)?.click()
            device.wait(Until.hasObject(By.text("编辑钱包 · 证件")), 3_000)
        }
        visible("编辑钱包 · 证件")
        device.waitForIdle()
    }

    @Test fun createAndEditDocumentFieldsPreservingCustomFields() = runBlocking<Unit> {
        val id = UUID.randomUUID().toString()
        val dir = File(context.cacheDir, "ui-test-$id")
        val prefs = context.getSharedPreferences("ui", 0)
        val chinese = prefs.getBoolean("chinese", true)
        prefs.edit().putBoolean("chinese", true).commit()
        var vault = VaultRepository(context, dir)
        var scenario: ActivityScenario<MainActivity>? = null
        try {
            withTimeout(10_000) { while (!vault.state.value.ready) delay(10) }
            vault.authenticate("1", true)
            val custom = JSONArray().put(JSONObject().put("id", "fixture-address").put("group", "地址").put("label", "户籍地址").put("kind", "text").put("value", "Fixture road 1"))
            assertTrue(vault.save(VaultRepository.blank("identity").put("title", "Document fixture").put("identity", JSONObject().put("firstName", "Fixture").put("lastName", "Person")).put("customFields", custom)))
            vault.close()
            device.wakeUp()
            scenario = ActivityScenario.launch(
                Intent(context, MainActivity::class.java)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK)
                    .putExtra("uiTestVault", id),
            )
            unlockFromLockScreen(device)
            openDestination(device, "钱包")
            visible("Document fixture")
            device.findObject(By.text("Document fixture")).click()
            visible("户籍地址")
            openEditor()
            type("证件类型", "居民身份证")
            type("证件号码", "FIXTURE-0001")
            type("签发日期", "2024-13-01")
            device.findObject(By.text("保存")).click()
            visible("请输入有效日期，格式 YYYY-MM-DD")
            assertFalse("Invalid date blocks saving", device.wait(Until.gone(By.text("编辑钱包 · 证件")), 1_500))
            type("签发日期", "2024-01-02")
            device.findObject(By.text("保存")).click()
            assertTrue("Editor closed", device.wait(Until.gone(By.text("保存")), 10_000))
            visible("居民身份证")
            visible("户籍地址")
            assertFalse("Document number is concealed", device.hasObject(By.text("FIXTURE-0001")))
            assertFalse("Blank expiry is not shown", device.hasObject(By.text("有效期至")))

            // Edit again: change one value and make sure nothing else is lost.
            openEditor()
            type("签发机关", "Fixture authority")
            device.findObject(By.text("保存")).click()
            assertTrue(device.wait(Until.gone(By.text("保存")), 10_000))
            visible("Fixture authority")
            scenario.close(); scenario = null

            // The activity's repository closes asynchronously; reopen once its session lock is released.
            withTimeout(20_000) {
                while (true) {
                    vault = VaultRepository(context, dir)
                    while (!vault.state.value.ready) delay(10)
                    if (vault.state.value.error == null) {
                        vault.authenticate("1", false)
                        if (vault.state.value.unlocked) break
                    }
                    vault.close()
                    delay(500)
                }
            }
            val saved = vault.state.value.entries.first { it.optString("title") == "Document fixture" }
            assertEquals(setOf("firstName", "lastName"), saved.getJSONObject("identity").keys().asSequence().toSet())
            val fields = saved.getJSONArray("customFields")
            fun byId(key: String) = (0 until fields.length()).map { fields.getJSONObject(it) }.first { it.optString("id") == key }
            assertEquals("Fixture road 1", byId("fixture-address").getString("value"))
            assertEquals("户籍地址", byId("fixture-address").getString("label"))
            byId("document.type").let { assertEquals("document", it.getString("group")); assertEquals("text", it.getString("kind")); assertEquals("居民身份证", it.getString("value")) }
            byId("document.number").let { assertEquals("concealed", it.getString("kind")); assertEquals("FIXTURE-0001", it.getString("value")) }
            byId("document.issueDate").let { assertEquals("date", it.getString("kind")); assertEquals("2024-01-02", it.getString("value")) }
            assertEquals("Fixture authority", byId("document.issuer").getString("value"))
            assertEquals(5, fields.length())
        } catch (failure: Throwable) {
            device.dumpWindowHierarchy(File(context.getExternalFilesDir(null), "identity-document-failure.xml"))
            throw failure
        } finally {
            scenario?.close()
            vault.close()
            dir.deleteRecursively()
            prefs.edit().putBoolean("chinese", chinese).commit()
        }
    }
}
