package com.securepass.vault

import android.content.Intent
import android.view.ViewGroup
import android.view.inputmethod.EditorInfo
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
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
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

/** Master-password re-verification, the no-personalized-learning IME request and the save-prompt setting. */
@RunWith(AndroidJUnit4::class)
class SecurityInputTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val context = instrumentation.targetContext
    private val device = UiDevice.getInstance(instrumentation)

    private suspend fun fixture(id: String): VaultRepository {
        val vault = VaultRepository(context, File(context.cacheDir, "ui-test-$id"))
        withTimeout(10_000) { while (!vault.state.value.ready) delay(10) }
        vault.authenticate("1", true)
        assertTrue(vault.state.value.unlocked)
        return vault
    }

    private fun launch(id: String) = ActivityScenario.launch<MainActivity>(
        Intent(context, MainActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK)
            .putExtra("uiTestVault", id),
    )

    @Test fun masterPasswordCheckIsReadOnlyAndRejectsWrongPasswords() = runBlocking<Unit> {
        val id = UUID.randomUUID().toString()
        val dir = File(context.cacheDir, "ui-test-$id")
        val vault = fixture(id)
        try {
            val header = File(dir, "vault/header.json").readBytes()
            assertFalse(vault.verifyMasterPassword("wrong"))
            assertFalse(vault.verifyMasterPassword(""))
            assertTrue(vault.verifyMasterPassword("1"))
            assertTrue("Verification keeps the session unlocked", vault.state.value.unlocked)
            assertArrayEquals("Verification never rewrites the header", header, File(dir, "vault/header.json").readBytes())
            vault.lock()
            assertTrue(vault.verifyMasterPassword("1"))
            assertFalse("Verification never unlocks", vault.state.value.unlocked)
        } finally {
            vault.close()
            dir.deleteRecursively()
        }
    }

    @Test fun reverifyDialogOnlyContinuesAfterTheCorrectPassword() = runBlocking<Unit> {
        val id = UUID.randomUUID().toString()
        fixture(id).close()
        val verified = mutableStateOf(0)
        val attempts = mutableListOf<String>()
        val scenario = launch(id)
        try {
            scenario.onActivity { activity ->
                activity.setContent {
                    MaterialTheme {
                        MasterPasswordReverifyDialog({ zh, _ -> zh }, verify = { attempts += it; it == "right" }, onVerified = { verified.value++ }, onDismiss = {})
                    }
                }
            }
            fun enter(password: String) {
                assertTrue(device.wait(Until.hasObject(By.clazz("android.widget.EditText")), 5_000))
                device.findObject(By.clazz("android.widget.EditText")).click()
                device.wait(Until.findObject(By.focused(true).clazz("android.widget.EditText")), 3_000).text = password
                device.findObject(By.text("继续")).click()
            }
            enter("wrong")
            assertTrue(device.wait(Until.hasObject(By.text("主密码不正确，指纹设置未改变。")), 5_000))
            assertEquals(0, verified.value)
            enter("right")
            withTimeout(5_000) { while (verified.value == 0) delay(20) }
            assertEquals(listOf("wrong", "right"), attempts)
        } finally {
            scenario.close()
            File(context.cacheDir, "ui-test-$id").deleteRecursively()
        }
    }

    @Test fun composeFieldsRequestNoPersonalizedLearning() = runBlocking<Unit> {
        assertEquals(EditorInfo.IME_FLAG_NO_PERSONALIZED_LEARNING, withoutPersonalizedLearning(0) and EditorInfo.IME_FLAG_NO_PERSONALIZED_LEARNING)
        val id = UUID.randomUUID().toString()
        fixture(id).close()
        val scenario = launch(id)
        try {
            scenario.onActivity { activity ->
                activity.setContent {
                    NoPersonalizedLearning {
                        MaterialTheme {
                            Surface(Modifier.fillMaxSize()) {
                                Column(Modifier.padding(top = 80.dp, start = 24.dp, end = 24.dp)) {
                                    val text = androidx.compose.runtime.remember { mutableStateOf("") }
                                    OutlinedTextField(text.value, { text.value = it }, label = { Text("Fixture") }, modifier = Modifier.semantics { contentDescription = "ime fixture" })
                                }
                            }
                        }
                    }
                }
            }
            val field = device.wait(Until.findObject(By.desc("ime fixture")), 5_000)
            assertNotNull(field)
            field.click()
            assertTrue(device.wait(Until.hasObject(By.focused(true).clazz("android.widget.EditText")), 3_000))
            var options = 0
            var connected = false
            scenario.onActivity { activity ->
                val compose = (activity.findViewById<ViewGroup>(android.R.id.content).getChildAt(0) as ViewGroup).getChildAt(0)
                val info = EditorInfo()
                connected = compose.onCreateInputConnection(info) != null
                options = info.imeOptions
            }
            assertTrue("Focused field has an input connection", connected)
            assertTrue("IME_FLAG_NO_PERSONALIZED_LEARNING requested", options and EditorInfo.IME_FLAG_NO_PERSONALIZED_LEARNING != 0)
        } finally {
            scenario.close()
            File(context.cacheDir, "ui-test-$id").deleteRecursively()
        }
    }

    @Test fun savePromptSwitchPersistsAndInlineSuggestionsAreDisabled() = runBlocking<Unit> {
        val prefs = context.getSharedPreferences(AppPreferences.FILE, 0)
        prefs.edit().remove(AppPreferences.AUTOFILL_SAVE_PROMPT).commit()
        assertTrue("Defaults on", AppPreferences.autofillSavePrompt(context))
        val id = UUID.randomUUID().toString()
        fixture(id).close()
        val scenario = launch(id)
        try {
            unlockFromLockScreen(device)
            assertTrue(device.wait(Until.hasObject(By.desc("设置")), 10_000))
            device.findObject(By.desc("设置")).click()
            assertTrue(device.wait(Until.hasObject(By.text("自动填充与通行密钥")), 5_000))
            device.findObject(By.text("自动填充与通行密钥")).click()
            val toggle = device.wait(Until.findObject(By.desc("提示保存新账号")), 5_000)
            assertNotNull(toggle)
            toggle.click()
            withTimeout(5_000) { while (AppPreferences.autofillSavePrompt(context)) delay(50) }
            device.findObject(By.desc("提示保存新账号")).click()
            withTimeout(5_000) { while (!AppPreferences.autofillSavePrompt(context)) delay(50) }
            assertTrue("Inline suggestions explain why they are off", device.hasObject(By.textStartsWith("暂不支持")))
            assertFalse("Inline suggestions stay off", device.findObject(By.desc("键盘内联建议")).isChecked)
        } catch (failure: Throwable) {
            device.dumpWindowHierarchy(File(context.getExternalFilesDir(null), "security-input-failure.xml"))
            throw failure
        } finally {
            scenario.close()
            prefs.edit().remove(AppPreferences.AUTOFILL_SAVE_PROMPT).commit()
            File(context.cacheDir, "ui-test-$id").deleteRecursively()
        }
    }
}
