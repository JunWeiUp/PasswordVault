package com.securepass.vault

import android.content.Intent
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.uiautomator.By
import androidx.test.uiautomator.UiDevice
import java.io.File
import java.util.UUID
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith

/** Synthetic presentation states; this does not pretend to connect to a relay. */
@RunWith(AndroidJUnit4::class)
class RelaySyncScreenTest {
    @Test fun syncStatusAndTransferProgressRemainDistinct() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        val id = UUID.randomUUID().toString()
        val device = UiDevice.getInstance(instrumentation)
        val initial = RelayUi(paired = true, mesh = true, pending = 2, status = "已连接 / Connected",
            sync = RelaySyncProgress(phase = RelaySyncPhase.CHECKED))
        val state = mutableStateOf(initial)
        val dark = mutableStateOf(false)
        var requests = 0
        var scenario: ActivityScenario<MainActivity>? = null
        fun visible(text: String) {
            val deadline = android.os.SystemClock.elapsedRealtime() + 8_000
            while (android.os.SystemClock.elapsedRealtime() < deadline) {
                if (android.os.Build.VERSION.SDK_INT >= 33) instrumentation.uiAutomation.clearCache()
                if (device.hasObject(By.text(text))) return
                Thread.sleep(100)
            }
            fail("Missing sync feedback: $text")
        }
        fun shot(name: String) {
            instrumentation.waitForIdleSync(); Thread.sleep(350)
            assertTrue(device.takeScreenshot(File(context.getExternalFilesDir(null), "sync-progress-$name.png")))
        }
        try {
            device.wakeUp(); device.executeShellCommand("wm dismiss-keyguard")
            scenario = ActivityScenario.launch(Intent(context, MainActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK)
                .putExtra("uiTestVault", id).putExtra("qaScreenshots", true))
            scenario.onActivity { activity -> activity.setContent {
                LegacyVaultTheme(dark.value) {
                    Surface(Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.background) {
                        Column(Modifier.padding(top = 52.dp, bottom = 24.dp).verticalScroll(rememberScrollState()).padding(12.dp)) {
                            Text("同步与设备", Modifier.padding(12.dp), style = MaterialTheme.typography.titleLarge)
                            RelaySyncCard(state.value, { chinese, _ -> chinese }) {
                                requests++
                                state.value = state.value.copy(sync = state.value.sync.copy(phase = RelaySyncPhase.REQUESTED))
                            }
                        }
                    }
                }
            } }
            visible("已同步"); shot("checked")
            device.findObject(By.text("立即同步")).click()
            visible("准备同步…"); visible("同步中…")
            assertEquals(1, requests)
            var button = device.findObject(By.text("同步中…"))
            while (!button.isClickable && button.parent != null) button = button.parent
            assertFalse("Duplicate sync requests must be disabled", button.isEnabled)
            instrumentation.runOnMainSync { state.value = initial.copy(sync = RelaySyncProgress(RelaySyncPhase.SENDING, 2, 4)) }
            visible("已处理 2 / 4 个传输分段"); shot("sending")
            instrumentation.runOnMainSync { state.value = initial.copy(sync = RelaySyncProgress(RelaySyncPhase.FAILED), error = "同步连接或传输超时，本地改动已保留 / Sync timed out; local changes retained") }
            visible("同步未完成"); visible("重试同步"); visible("同步连接或传输超时，本地改动已保留"); shot("failed")
            instrumentation.runOnMainSync { state.value = initial.copy(sync = RelaySyncProgress(RelaySyncPhase.WAITING_FOR_CAPABILITY)); dark.value = true }
            visible("等待安全格式协商"); shot("negotiating-dark")
            assertEquals("Presentation must never clear the pending queue", 2, state.value.pending)
        } finally {
            scenario?.close()
            File(context.cacheDir, "ui-test-$id").deleteRecursively()
        }
    }
}
