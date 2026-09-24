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
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith

/** README images use an isolated encrypted fixture, never the installed user's vault. */
@RunWith(AndroidJUnit4::class)
class ReadmeScreenshotsTest {
    @Test
    fun englishNativeScreenshotsAndConsistentCreation() = runBlocking {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        val device = UiDevice.getInstance(instrumentation)
        val preferences = context.getSharedPreferences("ui", 0)
        val hadLanguage = preferences.contains("chinese")
        val previousLanguage = preferences.getBoolean("chinese", true)
        val theme = InstrumentationRegistry.getArguments().getString("designTheme") ?: "light"
        val id = UUID.randomUUID().toString()
        val directory = File(context.cacheDir, "ui-test-$id")
        val fixture = VaultRepository(context, directory)
        var scenario: ActivityScenario<MainActivity>? = null
        try {
            while (!fixture.state.value.ready) delay(10)
            fixture.authenticate("1", true)
            assertTrue(
                fixture.mutate(
                    "settings",
                    JSONObject()
                        .put(
                            "settings",
                            JSONObject()
                                .put("theme", theme)
                                .put(
                                    "noteCategories",
                                    JSONArray(listOf("Personal", "Family", "Work")),
                                ),
                        ),
                )
            )
            val notes =
                listOf(
                    "Family essentials" to
                        "Keep everyday family details together.\n\n## Emergency contacts\n- Family email: family@example.com\n- Building service: Example contact\n\n## Important documents\nIDs and contracts are in the study cabinet.",
                    "A quiet weekend" to
                        "Visit the flower market and read at a cafe.\nCook dinner for the family.",
                    "The next trip" to
                        "A few days by the sea.\n\n- Pack light\n- Book train tickets\n- Charge the camera\n\nLeave an afternoon unplanned.",
                    "Ideas to keep" to
                        "Give important things a quiet place.\nMake complicated steps feel simple.",
                    "Reading notes" to
                        "Read slowly and write down what stays with you.\n\nDo the important things first.",
                    "Devices and warranties" to
                        "Keep model numbers, receipts and warranty details together.\n\nRouter manual filed in the study.",
                )
            notes.reversed().forEach { (title, body) ->
                assertTrue(
                    fixture.save(
                        VaultRepository.blank("secureNote")
                            .put("title", title)
                            .put("note", body)
                            .put(
                                "category",
                                if (title in listOf("Family essentials", "Devices and warranties"))
                                    "Family"
                                else "Personal",
                            )
                            .put("isPinned", title == "Family essentials")
                            .put("isFavorite", title == "Reading notes")
                    )
                )
            }
            assertTrue(
                fixture.save(
                    VaultRepository.blank("password")
                        .put("title", "Family email")
                        .put("username", "family@example.com")
                        .put("password", "Fictional only 123!")
                        .put("url", "https://example.com")
                        .put("category", "Family")
                        .put("tags", JSONArray(listOf("Home", "Important")))
                        .put("isFavorite", true)
                )
            )
            fixture.close()
            assertTrue(preferences.edit().putBoolean("chinese", false).commit())
            scenario =
                ActivityScenario.launch<MainActivity>(
                    Intent(context, MainActivity::class.java)
                        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK)
                        .putExtra("uiTestVault", id)
                        .putExtra("qaScreenshots", true)
                )
            assertTrue(device.wait(Until.hasObject(By.text("Unlock your vault")), 10_000))
            device.findObjects(By.clazz("android.widget.EditText"))[0].text = "1"
            device.findObject(By.text("Unlock")).click()
            assertTrue(device.wait(Until.hasObject(By.text("Family email")), 10_000))
            val creationBounds = device.findObject(By.desc("Add")).visibleBounds
            for (destination in listOf("Codes", "Wallets", "Notes", "Accounts")) {
                device.findObject(By.desc(destination)).click()
                assertTrue(device.wait(Until.hasObject(By.desc("Add")), 5_000))
                device.waitForIdle()
                val bounds = device.findObject(By.desc("Add")).visibleBounds
                assertEquals(
                    "Creation target must have the same width on $destination",
                    creationBounds.width(),
                    bounds.width(),
                )
                assertEquals(
                    "Creation target must have the same height on $destination",
                    creationBounds.height(),
                    bounds.height(),
                )
            }
            fun shot(name: String) {
                device.waitForIdle()
                val hierarchy = File(context.cacheDir, "readme-$id.xml")
                device.dumpWindowHierarchy(hierarchy)
                val nodes =
                    javax.xml.parsers.DocumentBuilderFactory.newInstance()
                        .newDocumentBuilder()
                        .parse(hierarchy)
                        .getElementsByTagName("node")
                for (index in 0 until nodes.length) {
                    val node = nodes.item(index) as org.w3c.dom.Element
                    // System signal/battery AX labels follow the emulator OS locale and are
                    // not visible screenshot text. Check all app text and AX names instead.
                    if (node.getAttribute("package") == context.packageName) {
                        assertFalse(
                            "Screenshot must contain English UI and fictional English data",
                            Regex("[\\u3400-\\u9fff]")
                                .containsMatchIn(
                                    node.getAttribute("text") + node.getAttribute("content-desc")
                                ),
                        )
                    }
                }
                hierarchy.delete()
                assertTrue(
                    device.takeScreenshot(
                        File(context.getExternalFilesDir(null), "readme-$theme-$name-en.png")
                    )
                )
            }
            device.findObject(By.text("Family email")).click()
            assertTrue(device.wait(Until.hasObject(By.text("Edit account")), 5_000))
            shot("account-editor")
            device.pressBack()
            assertTrue(device.wait(Until.hasObject(By.desc("Notes")), 5_000))
            device.findObject(By.desc("Notes")).click()
            assertTrue(device.wait(Until.hasObject(By.text("Family essentials")), 5_000))
            shot("notes")
            device.findObject(By.desc("Add")).click()
            assertTrue(device.wait(Until.hasObject(By.text("Edit note")), 5_000))
            device.findObject(By.text("Cancel")).click()
            assertTrue(device.wait(Until.hasObject(By.text("Family essentials")), 5_000))
            device.findObject(By.text("Family essentials")).click()
            assertTrue(device.wait(Until.hasObject(By.desc("Edit")), 5_000))
            device.findObject(By.desc("Edit")).click()
            assertTrue(device.wait(Until.hasObject(By.text("Edit note")), 5_000))
            shot("note-editor")
            device.findObject(By.text("Cancel")).click()
            device.findObject(By.desc("Lock")).click()
            assertTrue(device.wait(Until.hasObject(By.text("Unlock your vault")), 5_000))
        } finally {
            scenario?.close()
            fixture.close()
            val edit = preferences.edit()
            if (hadLanguage) edit.putBoolean("chinese", previousLanguage)
            else edit.remove("chinese")
            assertTrue(edit.commit())
        }
    }
}
