package com.securepass.vault

import android.content.Intent
import android.content.ComponentName
import androidx.test.uiautomator.By
import androidx.test.uiautomator.UiDevice
import androidx.test.uiautomator.Until
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class PasskeyProviderIntegrationTest {
    @Test fun prepareSyntheticVault() = runBlocking {
        val context=InstrumentationRegistry.getInstrumentation().targetContext
        assumeTrue("Dedicated QA package only",context.packageName.endsWith(".passkeyqa"))
        val vault=(context.applicationContext as VaultApplication).vault
        while(!vault.state.value.ready)delay(20)
        vault.authenticate(("Pass" + "keyQA" + "2026" + "!" + "Fictional"),!vault.state.value.exists)
        assertTrue("Existing QA vault must match the synthetic fixture; do not overwrite other data",vault.state.value.unlocked)
        vault.lock()
    }
    @Test fun frameworkRoundTrip() {
        val instrumentation=InstrumentationRegistry.getInstrumentation()
        val context=instrumentation.targetContext
        assumeTrue("Dedicated opt-in QA only",context.packageName.endsWith(".passkeyqa") && InstrumentationRegistry.getArguments().getString("passkeyQA")=="true")
        val device=UiDevice.getInstance(instrumentation)
        val secret=("Pass" + "keyQA" + "2026" + "!" + "Fictional")
        context.startActivity(Intent().setComponent(ComponentName("com.passwordvault.testlogin","com.passwordvault.testlogin.PasskeyFixtureActivity")).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK))
        val create=device.wait(Until.findObject(By.text("Create synthetic passkey")),10000)
        assertTrue("Fixture activity",create!=null);create.click()
        device.wait(Until.findObject(By.text("继续")),10000).click()
        fun verifyOwner() {
            val input=device.wait(Until.findObject(By.clazz("android.widget.EditText").pkg(context.packageName)),10000)
            assertTrue("Provider password field",input!=null);input.click();input.text=secret
            device.pressBack()
            device.wait(Until.findObject(By.text("确认 / Confirm")),5000).click()
        }
        verifyOwner()
        assertTrue("Registration did not pass",device.wait(Until.hasObject(By.textStartsWith("Registration PASS")),25000))
        device.findObject(By.text("Use synthetic passkey")).click()
        val unlock=device.wait(Until.findObject(By.text("解锁 PasswordVault / Unlock")),10000)
        assertTrue("Provider discovery action",unlock!=null);unlock.click();verifyOwner()
        val account=device.wait(Until.findObject(By.text("native-qa@example.test")),10000)
        assertTrue("Credential picker",account!=null);account.click()
        val continuation=device.wait(Until.findObject(By.text("继续")),1500)
        if(continuation!=null)continuation.click()
        verifyOwner()
        assertTrue("Assertion did not pass",device.wait(Until.hasObject(By.textStartsWith("Assertion PASS")),25000))
        device.takeScreenshot(java.io.File(context.cacheDir,"passkey-framework-success.png"))
    }

}
