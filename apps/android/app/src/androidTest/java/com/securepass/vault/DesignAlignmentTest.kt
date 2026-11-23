package com.securepass.vault

import android.content.Intent
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.uiautomator.By
import androidx.test.uiautomator.UiDevice
import androidx.test.uiautomator.Until
import androidx.test.uiautomator.UiScrollable
import androidx.test.uiautomator.UiSelector
import java.io.File
import java.util.UUID
import kotlinx.coroutines.*
import org.json.JSONObject
import org.json.JSONArray
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith

/** The design's fictional records are reproduced in a UUID-isolated encrypted vault. */
@RunWith(AndroidJUnit4::class)
class DesignAlignmentTest {
    @Test fun captureReferencePagesAndCategorySafety() = runBlocking<Unit> {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        val device = UiDevice.getInstance(instrumentation)
        val id = UUID.randomUUID().toString()
        val dir = File(context.cacheDir, "ui-test-$id")
        val prefs = context.getSharedPreferences("ui", 0)
        val chinese = prefs.getBoolean("chinese", true)
        prefs.edit().putBoolean("chinese", true).commit()
        val vault = VaultRepository(context, dir)
        var scenario: ActivityScenario<MainActivity>? = null
        fun text(label: String) = device.wait(Until.findObject(By.text(label)), 8_000).also { assertNotNull("Missing $label", it) }
        fun desc(label: String) = device.wait(Until.findObject(By.desc(label)), 8_000).also { assertNotNull("Missing action $label", it) }
        fun click(label: String) {
            device.waitForIdle(); Thread.sleep(150)
            try { text(label).click() } catch (_: androidx.test.uiautomator.StaleObjectException) { text(label).click() }
            Thread.sleep(250); device.waitForIdle()
        }
        fun action(label: String) {
            device.waitForIdle(); Thread.sleep(150)
            try { desc(label).click() } catch (_: androidx.test.uiautomator.StaleObjectException) { desc(label).click() }
            Thread.sleep(250); device.waitForIdle()
        }
        fun shot(name: String) {
            Thread.sleep(350); device.waitForIdle()
            device.takeScreenshot(File(context.getExternalFilesDir(null), "align-$name.png"))
        }
        fun root(label: String) { action(label) }
        suspend fun drawer(label: String) {
            action("打开导航"); delay(1_000)
            if (!device.hasObject(By.text(label))) UiScrollable(UiSelector().scrollable(true)).scrollTextIntoView(label)
            text(label).parent.click()
            assertTrue(device.wait(Until.gone(By.text("PasswordVault")), 5_000))
        }
        try {
            withTimeout(10_000) { while (!vault.state.value.ready) delay(10) }
            vault.authenticate("1", true)
            val theme = InstrumentationRegistry.getArguments().getString("designTheme") ?: "light"
            assertTrue(vault.mutate(CoreRequest.settings(JSONObject().put("theme", theme))))
            val notes = listOf(
                Triple("家庭重要资料", "家庭", "集中保存家庭常用信息，查找时更省心。"),
                Triple("设备与保修信息", "家庭", "记录家中设备型号、购买信息与保修情况。"),
                Triple("旅行准备清单", "旅行", "出行前的物品、证件和预订信息整理。"),
                Triple("恢复信息存放位置", "个人", "记录重要账号的恢复方式和存放位置。"),
                Triple("订阅与到期提醒", "工作", "管理各类订阅服务与到期时间提醒。"),
                Triple("工作交接备忘", "工作", "整理工作交接的账号、文档和注意事项。"),
            )
            notes.forEachIndexed { index, (title, category, body) ->
                assertTrue(vault.save(VaultRepository.blank("secureNote").put("title", title).put("category", category).put("note", body).put("isPinned", index == 0).put("isFavorite", index == 0)))
            }
            for ((title, category) in listOf("GitHub" to "工作", "Apple ID" to "个人", "公司邮箱" to "工作", "Figma" to "工作", "招商银行" to "金融", "家庭 Wi-Fi" to "家庭")) {
                assertTrue(vault.save(VaultRepository.blank("password").put("title", title).put("category", category).put("username", "lin.dev@example.com").put("url", "https://github.com").put("password", if (title in listOf("公司邮箱", "Figma")) "fixture" else "Only a synthetic fixture #42").put("isFavorite", title in listOf("GitHub", "Apple ID")).put("isPinned", title == "GitHub")))
            }
            for (issuer in listOf("GitHub", "Google", "Cloudflare")) assertTrue(vault.save(VaultRepository.blank("totp").put("title", issuer).put("issuer", issuer).put("username", "lin.dev@example.com").put("secret", "A".repeat(32))))
            assertTrue(vault.save(VaultRepository.blank("creditCard").put("title", "招行信用卡").put("card", JSONObject().put("brand", "银联").put("cardholder", "LIN XIAO").put("number", "0000000000005678").put("expiryMonth", "08").put("expiryYear", "2029").put("securityCode", "000"))))
            assertTrue(vault.save(VaultRepository.blank("identity").put("title", "身份证").put("identity", JSONObject().put("firstName", "示例").put("lastName", "林"))))
            assertTrue(vault.save(VaultRepository.blank("crypto").put("title", "以太坊钱包").put("network", "Ethereum 主网").put("address", "0x8a3F1c9E2b7D4a6C0e5F9b1A2d3C4e5F6a7B8c9D").put("mnemonic", "abandon ".repeat(11) + "about")))
            val trashedAccount = VaultRepository.blank("password").put("title", "旧论坛账号").put("username", "lin_2015").put("url", "https://forum.example.org").put("password", "Synthetic archived account #42")
            assertTrue(vault.save(trashedAccount))
            assertTrue(vault.trash(trashedAccount))
            assertTrue(vault.mutate(CoreRequest.categoryAdd("收据")))
            assertTrue(vault.mutate(CoreRequest.settings(JSONObject().put("collectionSort", JSONObject().put("secureNote", "titleAsc").put("password", "titleAsc")))))
            vault.close()
            device.wakeUp(); device.executeShellCommand("wm dismiss-keyguard")
            scenario = ActivityScenario.launch(Intent(context, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK).putExtra("uiTestVault", id).putExtra("qaScreenshots", true))
            text("PasswordVault 已锁定"); shot("lock")
            device.findObjects(By.clazz("android.widget.EditText"))[0].text = "1"; action("解锁")
            text("家庭重要资料"); shot("notes")
            action("切换列表"); shot("notesList")
            click("家庭重要资料"); text("集中保存家庭常用信息，查找时更省心。"); shot("noteRead")
            click("编辑"); shot("noteEdit"); device.pressBack(); device.waitForIdle(); device.pressBack(); device.waitForIdle()
            action("切换网格")
            // Category controls are horizontally scrollable, matching the design.
            UiScrollable(UiSelector().className("android.widget.HorizontalScrollView").scrollable(true)).setAsHorizontalList().scrollTextIntoView("收据 0")
            click("收据 0"); text("这个分类还没有笔记"); shot("noteEmpty")
            UiScrollable(UiSelector().className("android.widget.HorizontalScrollView").scrollable(true)).setAsHorizontalList().scrollTextIntoView("管理")
            click("管理"); text("笔记分类"); shot("noteCats")
            device.pressBack(); device.waitForIdle()
            root("账号"); text("GitHub"); shot("accounts")
            click("GitHub"); text("登录信息"); shot("acc")
            action("编辑"); text("编辑账号"); shot("accEdit"); device.pressBack(); device.waitForIdle(); device.pressBack(); device.waitForIdle()
            click("新建"); shot("accNew"); device.pressBack(); device.waitForIdle()
            root("验证码"); text("Cloudflare"); shot("codes")
            device.findObjects(By.desc("详情"))[0].click(); shot("code"); device.pressBack(); device.waitForIdle()
            click("添加"); shot("qr"); device.pressBack(); device.waitForIdle()
            root("钱包"); text("招行信用卡"); shot("wallets")
            for ((title, name) in listOf("招行信用卡" to "card", "身份证" to "idc", "以太坊钱包" to "crypto")) { click(title); shot(name); device.pressBack(); device.waitForIdle() }
            root("笔记"); action("打开导航"); delay(1_000); shot("drawer"); device.pressBack()
            drawer("全部项目"); shot("all"); drawer("个人收藏"); shot("fav")
            drawer("回收站"); text("旧论坛账号"); shot("trash")
            root("设置"); text("通用"); shot("settings")
            for ((label, name) in listOf("通用" to "s-general", "安全" to "s-security", "自动填充与通行密钥" to "s-autofill", "备份与导入" to "s-backup", "恢复密钥" to "s-recovery")) {
                click(label); shot(name); device.pressBack(); device.waitForIdle()
            }
            UiScrollable(UiSelector().scrollable(true)).scrollTextIntoView("密码生成器"); click("密码生成器"); shot("gen"); device.pressBack(); device.waitForIdle()
            UiScrollable(UiSelector().scrollable(true)).scrollTextIntoView("密码健康"); click("密码健康"); text("弱密码"); shot("health"); device.pressBack(); device.waitForIdle()
            // Verify on the live repository; ActivityScenario closes its model asynchronously.
            // Reopening here could race that model's shutdown and lock the replacement session.
            var activeVault: VaultRepository? = null
            val repositoryField = MainActivity::class.java.getDeclaredField("vault").apply { isAccessible = true }
            scenario!!.onActivity { activeVault = repositoryField.get(it) as VaultRepository }
            val checkVault = activeVault!!
            assertTrue(checkVault.state.value.unlocked)
            // Delete a populated category through the existing core command: notes must survive.
            val noteIds = checkVault.state.value.entries.filter { it.optString("type") == "secureNote" }.map { it.getString("id") }.toSet()
            assertTrue(checkVault.mutate(CoreRequest.categoryRemove("家庭", java.time.Instant.now().toString())))
            assertEquals(noteIds, checkVault.state.value.entries.filter { it.optString("type") == "secureNote" }.map { it.getString("id") }.toSet())
            assertFalse(checkVault.state.value.entries.any { it.optString("type") == "secureNote" && it.optString("category") == "家庭" })
        } catch (failure: Throwable) {
            shot("failure"); device.dumpWindowHierarchy(File(context.getExternalFilesDir(null), "align-failure.xml")); throw failure
        } finally {
            scenario?.close(); vault.close(); dir.deleteRecursively(); prefs.edit().putBoolean("chinese", chinese).commit()
        }
    }
}
