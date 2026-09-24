package com.securepass.vault

import android.content.ComponentName
import android.content.Intent
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.uiautomator.By
import androidx.test.uiautomator.UiDevice
import androidx.test.uiautomator.Until
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class AutofillFlowTest {
    @Test
    fun externalAppFillRequiresExplicitSelection() = runBlocking {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        val vault = (context.applicationContext as VaultApplication).vault
        while (!vault.state.value.ready) kotlinx.coroutines.delay(10)
        val password = "Autofill QA vault 123!"
        vault.authenticate(password, !vault.state.value.exists)
        assumeTrue(
            "Default preview vault uses a different password; preserve it",
            vault.state.value.unlocked,
        )
        val item =
            VaultRepository.blank("password")
                .put("title", "Autofill synthetic fixture")
                .put("username", "qa@example.test")
                .put("password", "Autofill fake password 123!")
                .put("url", "https://example.test")
        assertTrue(vault.save(item))
        vault.lock()
        val device = UiDevice.getInstance(instrumentation)
        val original = device.executeShellCommand("settings get secure autofill_service").trim()
        try {
            device.executeShellCommand(
                "settings put secure autofill_service ${context.packageName}/com.securepass.vault.VaultAutofillService"
            )
            context.startActivity(
                Intent()
                    .setComponent(
                        ComponentName(
                            "com.passwordvault.testlogin",
                            "com.passwordvault.testlogin.LoginActivity",
                        )
                    )
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK)
            )
            assertTrue(device.wait(Until.hasObject(By.text("Request Autofill")), 10_000))
            device.findObject(By.text("Request Autofill")).click()
            val prompt = device.wait(Until.findObject(By.textContains("PasswordVault ·")), 10_000)
            assertNotNull("System Autofill prompt", prompt)
            prompt.click()
            assertTrue(device.wait(Until.hasObject(By.text("解锁资料库")), 10_000))
            device.findObjects(By.clazz("android.widget.EditText"))[0].text = password
            device.findObject(By.text("解锁")).click()
            assertTrue(device.wait(Until.hasObject(By.text("Autofill synthetic fixture")), 10_000))
            device.findObject(By.text("Autofill synthetic fixture")).click()
            assertTrue(device.wait(Until.hasObject(By.text("向此应用填入？ / Fill this app?")), 5_000))
            device.findObject(By.text("确认填入 / Fill")).click()
            assertTrue(device.wait(Until.hasObject(By.text("qa@example.test")), 10_000))
            assertFalse(device.hasObject(By.text("Submitted only by explicit tap")))
        } finally {
            if (original == "null" || original.isBlank())
                device.executeShellCommand("settings delete secure autofill_service")
            else device.executeShellCommand("settings put secure autofill_service $original")
            vault.authenticate(password, false)
            if (vault.state.value.unlocked) {
                vault.trash(item)
                vault.remove(org.json.JSONObject(item.toString()).put("isDeleted", true))
                vault.lock()
            }
        }
    }
}
