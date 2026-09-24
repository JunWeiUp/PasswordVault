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
    fun localizedNativeScreenshotsAndConsistentCreation() = runBlocking {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        val device = UiDevice.getInstance(instrumentation)
        val preferences = context.getSharedPreferences("ui", 0)
        val hadLanguage = preferences.contains("chinese")
        val previousLanguage = preferences.getBoolean("chinese", true)
        val theme = InstrumentationRegistry.getArguments().getString("designTheme") ?: "light"
        val language = InstrumentationRegistry.getArguments().getString("designLanguage") ?: "en"
        val english = language != "zh"
        val extraAccount =
            InstrumentationRegistry.getArguments().getString("designExtraAccount") == "true"
        val translations =
            mapOf(
                "Unlock your vault" to "解锁资料库",
                "Unlock" to "解锁",
                "Add" to "新建",
                "Codes" to "验证码",
                "Wallets" to "钱包",
                "Notes" to "笔记",
                "Accounts" to "账号",
                "Edit account" to "编辑账号",
                "Edit note" to "编辑笔记",
                "Edit" to "编辑",
                "Cancel" to "取消",
                "Lock" to "锁定",
                "Collection tools" to "资料工具",
                "Select" to "选择",
                "Done selecting" to "完成选择",
                "All notes" to "全部笔记",
                "Password 2" to "密码 2",
                "Show Password 2" to "显示密码 2",
                "Hide Password 2" to "隐藏密码 2",
                "Family email" to "家庭邮箱",
                "Family essentials" to "家庭重要资料",
                "Personal" to "个人",
                "Family" to "家庭",
                "Work" to "工作",
                "Home" to "家用",
                "Important" to "重要",
                "A quiet weekend" to "周末的小计划",
                "The next trip" to "下一次旅行",
                "Ideas to keep" to "灵感收集",
                "Reading notes" to "读书随记",
                "Devices and warranties" to "设备与保修",
            )
        fun label(value: String) = if (english) value else translations.getValue(value)
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
                    JSONObject().put("settings", JSONObject().put("theme", theme)),
                )
            )
            // Categories are core-owned; generic settings intentionally ignore this field.
            for (category in listOf("Personal", "Family", "Work")) {
                assertTrue(
                    fixture.mutate("category-add", JSONObject().put("name", label(category)))
                )
            }
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
                    .mapIndexed { index, (title, body) ->
                        label(title) to
                            if (english) body
                            else
                                listOf(
                                    "集中保存家庭常用信息，查找时更省心。\n\n## 紧急联系\n- 家庭邮箱：family@example.com\n- 物业服务：示例联系人\n\n## 重要文件\n证件与合同放在书房文件柜第二层。",
                                    "逛花市，带一本书去咖啡馆。\n晚上给家人做一顿饭。",
                                    "想去看看海。\n\n- 轻便行李\n- 预订车票\n- 整理相机\n\n留半天时间，什么也不安排。",
                                    "让重要的事情有一个安静的位置。\n把复杂的步骤变得简单。",
                                    "一边阅读，一边记录自己的理解。\n\n先做重要的事。",
                                    "记录家中设备型号、购买信息与保修情况。\n\n路由器说明书已归档。",
                                )[index]
                    }
            notes.reversed().forEach { (title, body) ->
                assertTrue(
                    fixture.save(
                        VaultRepository.blank("secureNote")
                            .put("title", title)
                            .put("note", body)
                            .put(
                                "category",
                                if (title in listOf(notes[0].first, notes[5].first)) label("Family")
                                else label("Personal"),
                            )
                            .put("isPinned", title == notes[0].first)
                            .put("isFavorite", title == notes[4].first)
                    )
                )
            }
            assertTrue(
                fixture.save(
                    VaultRepository.blank("password")
                        .put("title", label("Family email"))
                        .put("username", "family@example.com")
                        .put("password", "Fictional only 123!")
                        .put("url", "https://example.com")
                        .put("category", label("Family"))
                        .put("tags", JSONArray(listOf("Home", "Important").map(::label)))
                        .put("isFavorite", true)
                        .apply {
                            if (extraAccount)
                                put(
                                    "accounts",
                                    JSONArray()
                                        .put(
                                            JSONObject()
                                                .put("id", UUID.randomUUID().toString())
                                                .put(
                                                    "label",
                                                    if (english) "Second login" else "备用账号",
                                                )
                                                .put("username", "second@example.com")
                                                .put("password", "Fictional second 123!")
                                        ),
                                )
                        }
                )
            )
            fixture.close()
            assertTrue(preferences.edit().putBoolean("chinese", !english).commit())
            scenario =
                ActivityScenario.launch<MainActivity>(
                    Intent(context, MainActivity::class.java)
                        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK)
                        .putExtra("uiTestVault", id)
                        .putExtra("qaScreenshots", true)
                )
            assertTrue(device.wait(Until.hasObject(By.text(label("Unlock your vault"))), 10_000))
            device.findObjects(By.clazz("android.widget.EditText"))[0].text = "1"
            device.findObject(By.text(label("Unlock"))).click()
            assertTrue(device.wait(Until.hasObject(By.text(label("Family email"))), 10_000))
            val creationBounds = device.findObject(By.desc(label("Add"))).visibleBounds
            for (destination in listOf("Codes", "Wallets", "Notes", "Accounts")) {
                device.findObject(By.desc(label(destination))).click()
                assertTrue(device.wait(Until.hasObject(By.desc(label("Add"))), 5_000))
                device.waitForIdle()
                val bounds = device.findObject(By.desc(label("Add"))).visibleBounds
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
                    if (english && node.getAttribute("package") == context.packageName) {
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
                        File(context.getExternalFilesDir(null), "readme-$theme-$name-$language.png")
                    )
                )
            }
            device.findObject(By.text(label("Family email"))).click()
            assertTrue(device.wait(Until.hasObject(By.text(label("Edit account"))), 5_000))
            shot("account-editor")
            if (extraAccount) {
                fun locate(
                    selector: androidx.test.uiautomator.BySelector
                ): androidx.test.uiautomator.UiObject2 {
                    repeat(24) {
                        if (android.os.Build.VERSION.SDK_INT >= 33)
                            instrumentation.uiAutomation.clearCache()
                        val target = device.findObject(selector)
                        if (target != null && target.visibleBounds.height() > 48) return target
                        val scroll = device.findObject(By.scrollable(true)).visibleBounds
                        device.swipe(
                            scroll.centerX(),
                            scroll.bottom - 80,
                            scroll.centerX(),
                            scroll.centerY(),
                            80,
                        )
                    }
                    error("Missing control $selector")
                }
                val passwordField = locate(By.desc(label("Password 2")))
                assertTrue(
                    "Large text must retain wide additional-password input",
                    passwordField.visibleBounds.width() > device.displayWidth * 0.6,
                )
                locate(By.desc(label("Show Password 2"))).click()
                assertTrue(device.wait(Until.hasObject(By.desc(label("Hide Password 2"))), 5_000))
                device.findObject(By.desc(label("Hide Password 2"))).click()
                shot("additional-account")
            }
            device.pressBack()
            assertTrue(device.wait(Until.hasObject(By.desc(label("Notes"))), 5_000))
            device.findObject(By.desc(label("Notes"))).click()
            assertTrue(device.wait(Until.hasObject(By.text(label("Family essentials"))), 5_000))
            shot("notes")
            device.findObject(By.text(label("All notes"))).click()
            assertTrue(device.wait(Until.hasObject(By.text(label("Work"))), 5_000))
            device.findObject(By.text(label("Work"))).click()
            assertTrue(device.wait(Until.gone(By.text(label("Family essentials"))), 5_000))
            device.findObject(By.text(label("Work"))).click()
            device.findObject(By.text(label("All notes"))).click()
            assertTrue(device.wait(Until.hasObject(By.text(label("Family essentials"))), 5_000))
            device.findObject(By.desc(label("Collection tools"))).click()
            assertTrue(device.wait(Until.hasObject(By.text(label("Select"))), 5_000))
            device.findObject(By.text(label("Select"))).click()
            assertTrue(device.wait(Until.hasObject(By.text(label("Done selecting"))), 5_000))
            assertFalse(device.hasObject(By.desc(label("Add"))))
            device.findObject(By.text(label("Done selecting"))).click()
            assertTrue(device.wait(Until.hasObject(By.desc(label("Add"))), 5_000))
            device.findObject(By.desc(label("Add"))).click()
            assertTrue(device.wait(Until.hasObject(By.text(label("Edit note"))), 5_000))
            device.findObject(By.text(label("Cancel"))).click()
            assertTrue(device.wait(Until.hasObject(By.text(label("Family essentials"))), 5_000))
            device.findObject(By.text(label("Family essentials"))).click()
            assertTrue(device.wait(Until.hasObject(By.desc(label("Edit"))), 5_000))
            device.findObject(By.desc(label("Edit"))).click()
            assertTrue(device.wait(Until.hasObject(By.text(label("Edit note"))), 5_000))
            shot("note-editor")
            device.findObject(By.text(label("Cancel"))).click()
            device.findObject(By.desc(label("Lock"))).click()
            assertTrue(device.wait(Until.hasObject(By.text(label("Unlock your vault"))), 5_000))
        } catch (error: Throwable) {
            device.dumpWindowHierarchy(
                File(context.getExternalFilesDir(null), "readme-failure.xml")
            )
            device.takeScreenshot(File(context.getExternalFilesDir(null), "readme-failure.png"))
            throw error
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
