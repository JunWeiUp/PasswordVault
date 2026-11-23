package com.securepass.vault

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.io.File
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeoutOrNull
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith

/**
 * Manual probe, emulator only: joins a real device group with a fresh synthetic vault and
 * reports how the first sync ends. `-e probeInvite <link> -e probePassword <server password>`.
 * The vault lives in app cache under `probe-vault`; `-e probeLeave true` leaves the group, then
 * deletes it (`-e probeClean true` only deletes it).
 */
@RunWith(AndroidJUnit4::class)
class RealGroupProbe {
    @Test fun joinRealGroupAndSync() = runBlocking {
        val args = InstrumentationRegistry.getArguments()
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val base = File(context.cacheDir, "probe-vault")
        if (args.getString("probeClean") == "true") { base.deleteRecursively(); return@runBlocking }
        val invite = args.getString("probeInvite"); val password = args.getString("probePassword")
        assumeTrue("probe arguments not provided", (invite != null && password != null) || args.getString("probeLeave") == "true")
        RelayLocalTest.capturePackets = true
        val vault = VaultRepository(context, base)
        try {
            withTimeoutOrNull(20_000) { while (!vault.state.value.ready) delay(100) }
            vault.authenticate("probe-fixture-password", !File(base, "vault").exists())
            withTimeoutOrNull(20_000) { while (!vault.state.value.unlocked) delay(100) }
            // Credentials load asynchronously after unlock; only join when this vault has no group.
            withTimeoutOrNull(20_000) { while (vault.relay.state.value.busy || vault.relay.state.value.status.isEmpty()) delay(100) }
            delay(2_000)
            if (args.getString("probeLeave") == "true") {
                if (vault.relay.state.value.managed) vault.relay.leaveGroup(false)
                withTimeoutOrNull(30_000) { while (vault.relay.state.value.managed || vault.relay.state.value.busy) delay(200) }
                android.util.Log.w("RealGroupProbe", "left: ${vault.relay.state.value.status}")
                vault.close(); base.deleteRecursively(); return@runBlocking
            }
            if (!vault.relay.state.value.managed) vault.relay.joinGroup(invite!!, "Emulator probe", password!!)
            var last = ""
            withTimeoutOrNull(150_000) {
                while (true) {
                    val s = vault.relay.state.value
                    val line = "status=${s.status} error=${s.error} mesh=${s.mesh} members=${s.members.map { it.name + ":" + it.online }} items=${vault.state.value.entries.size}"
                    if (line != last) { android.util.Log.w("RealGroupProbe", line); last = line }
                    delay(1000)
                }
            }
        } finally {
            RelayLocalTest.capturePackets = false
            vault.close()
        }
    }
}
