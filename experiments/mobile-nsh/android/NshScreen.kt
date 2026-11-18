package com.securepass.vault

import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.ui.Modifier
import androidx.compose.ui.viewinterop.AndroidView
import androidx.compose.foundation.layout.fillMaxSize
import com.longbridge.nsh.NshView
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.launch
import org.json.JSONObject

/**
 * Host functions the shared NSH mobile UI (apps/mobile) may call. Secrets never cross into
 * the NSH app: codes are computed here and copies go through [VaultRepository.copy], which
 * marks clips sensitive. Names match the bundle's `capabilities.host` grant.
 */
internal object NshHost {
    fun install(view: NshView, scope: CoroutineScope, vault: () -> VaultRepository, state: () -> VaultState, open: (String) -> Unit) {
        view.handle("vault.codes") { _, reply ->
            scope.launch {
                try {
                    reply.resolve(mapOf("codes" to codes(vault(), state())))
                } catch (_: Exception) {
                    reply.reject("Locked")
                }
            }
        }
        view.handle("clipboard.copy") { data, reply ->
            val text = (data as? Map<*, *>)?.get("text") as? String
            if (text.isNullOrEmpty()) reply.reject("InvalidData") else { vault().copy(text); reply.resolve(null) }
        }
        view.handle("vault.open") { data, reply ->
            val id = (data as? Map<*, *>)?.get("id") as? String
            if (id.isNullOrEmpty()) reply.reject("InvalidData") else { open(id); reply.resolve(null) }
        }
    }

    suspend fun codes(vault: VaultRepository, state: VaultState): List<Map<String, Any>> {
        val millis = System.currentTimeMillis()
        val seconds = millis / 1000
        return state.entries
            .filter { it.optString("type") == "totp" && !it.optBoolean("isDeleted") }
            .map { item ->
                // The core expects integer seconds, as the native list passes them.
                val period = item.optInt("period", 30).coerceAtLeast(1)
                val code = runCatching {
                    vault.command("totp", JSONObject().put("secret", item.optString("secret")).put("period", period).put("time", seconds))
                        .optString("code")
                }.getOrDefault("")
                mapOf(
                    "id" to item.optString("id"), "title" to item.optString("title"), "username" to item.optString("username"),
                    "code" to code, "period" to period, "remaining" to (period - (millis / 1000.0) % period),
                )
            }
            .sortedBy { (it["title"] as String).lowercase() }
    }
}

/** The codes list as the shared NSH page; details and editing stay native for now. */
@Composable
internal fun NshCodesScreen(vault: VaultRepository, state: VaultState, open: (String) -> Unit, modifier: Modifier = Modifier) {
    val scope = rememberCoroutineScope()
    val currentVault by rememberUpdatedState(vault)
    val currentState by rememberUpdatedState(state)
    val currentOpen by rememberUpdatedState(open)
    AndroidView(
        factory = { context ->
            NshView(context).apply {
                NshHost.install(this, scope, { currentVault }, { currentState }) { currentOpen(it) }
                loadAssetBundle("nsh")
            }
        },
        onRelease = { it.destroy() },
        modifier = modifier.fillMaxSize(),
    )
}
