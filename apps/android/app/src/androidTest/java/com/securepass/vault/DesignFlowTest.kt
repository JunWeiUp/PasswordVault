package com.securepass.vault

import android.content.Intent
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

@RunWith(AndroidJUnit4::class)
class DesignFlowTest {
    @Test
    fun accountFiltersAndNoteEditingPreserveContent() = runBlocking {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        val id = UUID.randomUUID().toString()
        val fixture = VaultRepository(context, File(context.cacheDir, "ui-test-$id"))
        while (!fixture.state.value.ready) delay(10)
        fixture.authenticate("1", true)
        val theme = InstrumentationRegistry.getArguments().getString("designTheme") ?: "light"
        assertTrue(
            fixture.mutate(
                "settings",
                JSONObject()
                    .put(
                        "settings",
                        JSONObject()
                            .put("theme", theme)
                            .put("noteCategories", JSONArray(listOf("个人", "家庭", "工作"))),
                    ),
            )
        )
        listOf("Northstar", "Paper & ink", "Sunday studio", "Atlas mail")
            .withIndex()
            .reversed()
            .forEach { (index, title) ->
                assertTrue(
                    fixture.save(
                        VaultRepository.blank("password")
                            .put("title", title)
                            .put(
                                "username",
                                listOf(
                                    "alex@example.com",
                                    "alex.writer@example.com",
                                    "hello@example.com",
                                    "alex@example.test",
                                )[index],
                            )
                            .put("password", "Fictional only 123!")
                            .put("url", "https://example.test")
                            .put("category", if (index == 1) "娱乐" else "工作")
                            .put("tags", JSONArray(listOf(if (index == 1) "写作" else "个人")))
                            .put("isFavorite", index == 0)
                    )
                )
            }
        val notes =
            listOf(
                "家庭重要资料" to
                    "集中保存家庭常用信息，查找时更省心。\n\n## 紧急联系\n- 家庭邮箱：family@example.com\n- 物业服务：示例联系人\n\n## 重要文件\n证件与合同放在书房文件柜第二层。",
                "周末的小计划" to "逛花市，带一本书去咖啡馆。\n晚上给家人做一顿饭。",
                "下一次旅行" to "想去看看海。\n\n- 轻便行李\n- 预订车票\n- 整理相机\n\n留半天时间，什么也不安排。",
                "灵感收集" to "让重要的事情有一个安静的位置。\n把复杂的步骤变得简单。",
                "读书随记" to "一边阅读，一边记录自己的理解。\n\n今天记住的一句话：先做重要的事。",
                "设备与保修" to "记录家中设备型号、购买信息与保修情况。\n\n路由器说明书已归档。",
            )
        notes.reversed().forEachIndexed { index, (title, body) ->
            assertTrue(
                fixture.save(
                    VaultRepository.blank("secureNote")
                        .put("title", title)
                        .put("note", body)
                        .put(
                            "category",
                            if (title.contains("家庭") || title.contains("设备")) "家庭" else "个人",
                        )
                        .put("isPinned", title == "家庭重要资料")
                        .put("isFavorite", title == "读书随记")
                )
            )
        }
        fixture.state.value.entries
            .filter { it.optString("type") == "secureNote" }
            .forEach {
                assertTrue(java.time.Instant.parse(it.optString("updatedAt")).toEpochMilli() > 0)
                assertFalse(
                    "Expected real note date: ${it.optString("updatedAt")}",
                    noteDate(it).isBlank(),
                )
            }
        fixture.close()
        val device = UiDevice.getInstance(instrumentation)
        val scenario =
            androidx.test.core.app.ActivityScenario.launch<MainActivity>(
                Intent(context, MainActivity::class.java)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK)
                    .putExtra("uiTestVault", id)
                    .putExtra("qaScreenshots", true)
            )
        assertTrue(device.wait(Until.hasObject(By.text("解锁资料库")), 10_000))
        device.findObjects(By.clazz("android.widget.EditText"))[0].text = "1"
        device.findObject(By.text("解锁")).click()
        assertTrue(device.wait(Until.hasObject(By.text("Northstar")), 10_000))
        fun shot(name: String) {
            device.takeScreenshot(
                File(context.getExternalFilesDir(null), "design-$theme-$name.png")
            )
        }
        shot("accounts")
        device.findObject(By.desc("仅看收藏")).click()
        assertTrue(device.wait(Until.gone(By.text("Paper & ink")), 5_000))
        assertTrue(device.hasObject(By.text("Northstar")))
        device.findObject(By.desc("仅看收藏")).click()
        device.findObject(By.desc("笔记")).click()
        assertTrue(device.wait(Until.hasObject(By.text("家庭重要资料")), 5_000))
        shot("notes")
        device.findObject(By.desc("切换列表")).click()
        assertTrue(device.wait(Until.hasObject(By.desc("切换网格")), 5_000))
        device.findObject(By.desc("切换网格")).click()
        assertTrue(device.wait(Until.hasObject(By.text("家庭重要资料")), 5_000))
        device.findObject(By.text("家庭重要资料")).click()
        assertTrue(device.wait(Until.hasObject(By.desc("编辑")), 5_000))
        shot("reader")
        device.findObject(By.desc("编辑")).click()
        assertTrue(device.wait(Until.hasObject(By.text("编辑笔记")), 5_000))
        shot("editor")
        val fields = device.findObjects(By.clazz("android.widget.EditText"))
        fields[1].click()
        fields[1].text = notes[0].second + "\n保留原文的新段落。"
        device.waitForIdle()
        assertTrue(device.findObject(By.text("保存")).visibleBounds.height() > 0)
        assertTrue(device.findObject(By.text("预览")).visibleBounds.height() > 0)
        shot("keyboard")
        device.findObject(By.desc("笔记信息")).click()
        assertTrue(device.wait(Until.hasObject(By.text("分类")), 5_000))
        val metadata = device.findObjects(By.clazz("android.widget.EditText"))
        metadata[0].text = "重要"
        metadata[1].text = "家庭, 归档"
        device.findObject(By.text("完成")).click()
        scenario.recreate()
        assertTrue(device.wait(Until.hasObject(By.text("编辑笔记")), 5_000))
        device.findObject(By.text("取消")).click()
        assertTrue(device.wait(Until.hasObject(By.text("保存这次修改？")), 5_000))
        device.findObject(By.text("继续编辑")).click()
        device.findObject(By.text("保存")).click()
        assertTrue(device.wait(Until.hasObject(By.textContains("保留原文的新段落。")), 5_000))
        device.findObject(By.desc("返回")).click()
        assertTrue(device.wait(Until.hasObject(By.text("家庭重要资料")), 5_000))
        device.findObject(By.text("家庭重要资料")).longClick()
        assertTrue(device.wait(Until.hasObject(By.text("取消置顶")), 5_000))
        device.findObject(By.text("取消置顶")).click()
        val search = device.findObject(By.clazz("android.widget.EditText"))
        search.text = "家庭重要"
        assertTrue(device.wait(Until.gone(By.text("周末的小计划")), 5_000))
        assertTrue(device.hasObject(By.text("家庭重要资料")))
        device.findObject(By.desc("清空搜索")).click()
        device.findObject(By.desc("锁定")).click()
        assertTrue(device.wait(Until.hasObject(By.text("解锁资料库")), 5_000))
        scenario.close()
    }
}
