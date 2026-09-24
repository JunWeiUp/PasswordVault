package com.securepass.vault

import android.content.Intent
import android.graphics.Rect
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.uiautomator.By
import androidx.test.uiautomator.BySelector
import androidx.test.uiautomator.Configurator
import androidx.test.uiautomator.UiDevice
import androidx.test.uiautomator.UiObject2
import androidx.test.uiautomator.Until
import java.io.File
import java.util.UUID
import java.util.regex.Pattern
import kotlin.math.abs
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith

/** Exercises real lazy-list gestures using a separate encrypted fixture and no real vault. */
@RunWith(AndroidJUnit4::class)
class NotesScrollTest {
    @Test
    fun wholePageScrollPreservesPositionAndHeaderActions() = runBlocking {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        val device = UiDevice.getInstance(instrumentation)
        val preferences = context.getSharedPreferences("ui", 0)
        val hadLanguage = preferences.contains("chinese")
        val priorLanguage = preferences.getBoolean("chinese", true)
        val configuration = Configurator.getInstance()
        val priorIdle = configuration.waitForIdleTimeout
        configuration.setWaitForIdleTimeout(400)
        val theme = InstrumentationRegistry.getArguments().getString("designTheme") ?: "light"
        val scale = context.resources.configuration.fontScale
        val id = UUID.randomUUID().toString()
        val fixture = VaultRepository(context, File(context.cacheDir, "ui-test-$id"))
        var scenario: ActivityScenario<MainActivity>? = null
        fun fresh() {
            if (android.os.Build.VERSION.SDK_INT >= 33) instrumentation.uiAutomation.clearCache()
        }
        fun visible(selector: BySelector): Boolean {
            fresh()
            return device.findObjects(selector).any {
                val rect = it.visibleBounds
                rect.width() > 0 && rect.height() > 0
            }
        }
        fun awaitVisible(selector: BySelector) {
            assertTrue(
                "Missing visible control: $selector",
                device.wait(Until.hasObject(selector), 5_000),
            )
            assertTrue("Control is outside the viewport: $selector", visible(selector))
        }
        fun scrollBounds(): Rect {
            fresh()
            return device
                .findObjects(By.scrollable(true))
                .maxByOrNull { it.visibleBounds.height() }
                ?.visibleBounds ?: error("Notes must provide one scrollable collection")
        }
        fun swipe(down: Boolean) {
            val rect = scrollBounds()
            val upper = rect.top + rect.height() / 5
            val lower = rect.bottom - rect.height() / 5
            // A slow gesture avoids fling-dependent anchors and never starts at screen edges.
            device.swipe(
                rect.centerX(),
                if (down) lower else upper,
                rect.centerX(),
                if (down) upper else lower,
                80,
            )
            device.waitForIdle()
            fresh()
        }
        fun topTitleVisible(): Boolean {
            fresh()
            // The selected tab exposes its text label instead of the icon description.
            // Settings remains an unselected icon while reviewing Notes.
            val tabTop = device.findObject(By.desc("Settings"))?.visibleBounds?.top ?: return false
            return device.findObjects(By.text("Notes")).any {
                it.visibleBounds.height() > 0 && it.visibleBounds.bottom < tabTop
            }
        }
        fun headerVisible(): Boolean =
            topTitleVisible() &&
                visible(By.desc("Lock")) &&
                visible(By.text("Search notes")) &&
                visible(By.text("All notes"))
        fun backToTop() {
            repeat(30) {
                if (headerVisible()) return
                swipe(false)
            }
            fail("The scrollable Notes header must remain reachable")
        }
        fun headerHidden() {
            assertFalse(
                "Notes title must scroll out, excluding the bottom tab label",
                topTitleVisible(),
            )
            assertFalse(
                "Search must scroll with the document collection",
                visible(By.text("Search notes")),
            )
            assertFalse(
                "Folder controls must scroll with the document collection",
                visible(By.text("All notes")),
            )
            assertFalse(
                "The header lock action must scroll with its title",
                visible(By.desc("Lock")),
            )
        }
        fun shot(name: String) {
            device.waitForIdle()
            assertTrue(
                device.takeScreenshot(
                    File(context.getExternalFilesDir(null), "notes-scroll-$theme-$scale-$name.png")
                )
            )
        }
        fun anchor(): Pair<String, Rect> {
            fresh()
            val viewport = scrollBounds()
            val target =
                device
                    .findObjects(By.text(Pattern.compile("Fixture note \\d{2}")))
                    .filter {
                        it.visibleBounds.top > viewport.top + 24 &&
                            it.visibleBounds.bottom < viewport.bottom - 120
                    }
                    .minWithOrNull(
                        compareBy<UiObject2> { it.visibleBounds.top }
                            .thenBy { it.visibleBounds.left }
                    ) ?: error("Expected a fully visible fictional note after scrolling")
            return target.text to Rect(target.visibleBounds)
        }
        fun samePosition(saved: Pair<String, Rect>, operation: String) {
            awaitVisible(By.text(saved.first))
            val rect = device.findObject(By.text(saved.first)).visibleBounds
            val tolerance = (context.resources.displayMetrics.density * 8).toInt()
            assertTrue(
                "$operation changed note position: ${saved.second.top} -> ${rect.top}",
                abs(rect.top - saved.second.top) <= tolerance,
            )
            headerHidden()
        }
        fun hideKeyboard() {
            // Focus and the IME window arrive asynchronously. Observe the actual input
            // window, then use Back exactly once; a premature inset read can miss it.
            var appeared = false
            for (attempt in 0 until 50) {
                if (
                    instrumentation.uiAutomation.windows.any {
                        it.type ==
                            android.view.accessibility.AccessibilityWindowInfo.TYPE_INPUT_METHOD
                    }
                ) {
                    appeared = true
                    break
                }
                android.os.SystemClock.sleep(100)
            }
            assertTrue("Search must show its keyboard before testing dismissal", appeared)
            device.pressBack()
            awaitVisible(By.desc("Settings"))
        }
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
                                .put("collectionSort", JSONObject().put("secureNote", "titleAsc")),
                        ),
                )
            )
            for (category in listOf("Family", "Work", "Empty folder")) {
                assertTrue(fixture.mutate("category-add", JSONObject().put("name", category)))
            }
            repeat(40) { index ->
                assertTrue(
                    fixture.save(
                        VaultRepository.blank("secureNote")
                            .put("title", "Fixture note ${String.format("%02d", index + 1)}")
                            .put(
                                "note",
                                "Fictional notes for the page-scroll review.\n\nKeep ideas and everyday details close.\n\nItem ${index + 1}; no personal information.",
                            )
                            .put("category", if (index % 2 == 0) "Family" else "Work")
                    )
                )
            }
            fixture.close()
            assertTrue(preferences.edit().putBoolean("chinese", false).commit())
            scenario =
                ActivityScenario.launch<MainActivity>(
                    Intent(context, MainActivity::class.java)
                        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK)
                        .putExtra("uiTestVault", id)
                        .putExtra("qaScreenshots", true)
                )
            awaitVisible(By.text("Unlock your vault"))
            device.findObjects(By.clazz("android.widget.EditText"))[0].text = "1"
            device.findObject(By.text("Unlock")).click()
            awaitVisible(By.desc("Notes"))
            device.findObject(By.desc("Notes")).click()
            awaitVisible(By.text("Fixture note 01"))
            for (mode in listOf("grid", "list")) {
                backToTop()
                if (mode == "list") {
                    device.findObject(By.desc("List view")).click()
                    awaitVisible(By.desc("Grid view"))
                }
                assertTrue(headerVisible())
                shot("$mode-before")
                repeat(4) { swipe(true) }
                headerHidden()
                awaitVisible(By.desc("Add"))
                awaitVisible(By.desc("Accounts"))
                assertTrue(
                    device.findObjects(By.text("Notes")).any {
                        it.visibleBounds.top >=
                            device.findObject(By.desc("Settings")).visibleBounds.top
                    }
                )
                val saved = anchor()
                shot("$mode-after")
                device.findObject(By.text(saved.first)).click()
                awaitVisible(By.desc("Edit"))
                device.findObject(By.desc("Back")).click()
                samePosition(saved, "$mode detail return")
                device.findObject(By.desc("Add")).click()
                awaitVisible(By.text("Edit note"))
                device.findObject(By.text("Cancel")).click()
                samePosition(saved, "$mode cancelled creation")
                device.findObject(By.desc("Accounts")).click()
                awaitVisible(By.text("Accounts"))
                assertFalse(
                    "The Accounts tab must actually leave the Notes collection",
                    visible(By.text(saved.first)),
                )
                device.findObject(By.desc("Notes")).click()
                samePosition(saved, "$mode tab return")
            }
            backToTop()
            device.findObject(By.text("All notes")).click()
            awaitVisible(By.text("Empty folder"))
            device.findObject(By.text("Empty folder")).click()
            awaitVisible(By.text("No matching entries"))
            awaitVisible(By.text("Clear filters"))
            device.findObject(By.text("Clear filters")).click()
            awaitVisible(By.text("Fixture note 01"))
            backToTop()
            val search = device.findObject(By.clazz("android.widget.EditText"))
            search.click()
            search.text = "no-fixture-match"
            hideKeyboard()
            awaitVisible(By.text("No matching entries"))
            device.findObject(By.text("Clear filters")).click()
            awaitVisible(By.text("Fixture note 01"))
            backToTop()
            device.findObject(By.desc("Collection tools")).click()
            awaitVisible(By.text("Select"))
            device.findObject(By.text("Select")).click()
            awaitVisible(By.text("Done selecting"))
            assertFalse(visible(By.desc("Add")))
            device.findObject(By.text("Done selecting")).click()
            awaitVisible(By.desc("Add"))
            backToTop()
            device.findObject(By.desc("Lock")).click()
            awaitVisible(By.text("Unlock your vault"))
        } catch (error: Throwable) {
            device.dumpWindowHierarchy(
                File(context.getExternalFilesDir(null), "notes-scroll-$theme-$scale-failure.xml")
            )
            shot("failure")
            throw error
        } finally {
            scenario?.close()
            fixture.close()
            val edit = preferences.edit()
            if (hadLanguage) edit.putBoolean("chinese", priorLanguage) else edit.remove("chinese")
            assertTrue(edit.commit())
            configuration.setWaitForIdleTimeout(priorIdle)
        }
    }
}
