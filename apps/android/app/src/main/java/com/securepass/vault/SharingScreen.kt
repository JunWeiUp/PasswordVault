package com.securepass.vault

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import java.time.Instant
import kotlinx.coroutines.launch
import org.json.JSONObject

@Composable
fun SharingScreen(vault: VaultRepository, state: VaultState, t: (String, String) -> String) {
    val peers by vault.sync.peers.collectAsStateWithLifecycle()
    val scope = rememberCoroutineScope()
    val endpoint by vault.sync.endpoint.collectAsStateWithLifecycle()
    var publicKey by remember { mutableStateOf("") }
    var name by remember { mutableStateOf("") }
    var selected by remember { mutableStateOf("") }
    var member by remember { mutableStateOf("") }
    var role by remember { mutableStateOf("viewer") }
    var join by remember { mutableStateOf("") }
    var busy by remember { mutableStateOf(false) }
    var message by remember { mutableStateOf<String?>(null) }
    fun run(work: suspend () -> Unit) {
        if (busy) return
        busy = true
        scope.launch {
            try {
                work()
                vault.refresh()
            } catch (_: Exception) {
                message =
                    t(
                        "操作未完成，请检查邀请、公钥和权限。",
                        "Check invitation, public key and permissions, then retry.",
                    )
            } finally {
                busy = false
            }
        }
    }
    LaunchedEffect(Unit) { run { publicKey = vault.command("identity").getString("publicKey") } }
    Column(
        Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(20.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        Text(t("共享资料库", "Shared vaults"), style = MaterialTheme.typography.headlineMedium)
        Text(
            t(
                "双方使用原生 V2 客户端，请当面或通过可信渠道核对公钥与邀请。",
                "Both devices need a native V2 client. Verify keys and invitations in person or through a trusted channel.",
            )
        )
        Text(publicKey, style = MaterialTheme.typography.bodySmall)
        TextButton(onClick = { vault.copy(publicKey) }) { Text(t("复制我的公钥", "Copy my public key")) }
        Input(t("新资料库名称", "New vault name"), name, { name = it })
        Button(
            enabled = name.isNotBlank() && !busy,
            onClick = {
                run {
                    selected =
                        vault
                            .command(
                                "create-shared",
                                JSONObject().put("name", name).put("time", Instant.now().toString()),
                            )
                            .getString("id")
                    name = ""
                }
            },
        ) {
            Text(t("创建资料库", "Create vault"))
        }
        state.sharedVaults.forEach { shared ->
            FilterChip(
                selected = selected == shared.optString("id"),
                onClick = { selected = shared.optString("id") },
                label = { Text(shared.optString("name")) },
            )
        }
        if (selected.isNotEmpty()) {
            Input(t("对方的共享公钥", "Recipient public key"), member, { member = it })
            Row {
                FilterChip(role == "viewer", { role = "viewer" }, { Text(t("只读", "Viewer")) })
                Spacer(Modifier.width(12.dp))
                FilterChip(role == "editor", { role = "editor" }, { Text(t("可编辑", "Editor")) })
            }
            Button(
                enabled = !busy && member.isNotBlank(),
                onClick = {
                    run {
                        vault.command(
                            "add-member",
                            JSONObject()
                                .put("vaultId", selected)
                                .put("publicKey", member.trim())
                                .put("role", role)
                                .put("name", ""),
                        )
                        member = ""
                    }
                },
            ) {
                Text(t("授权此成员", "Authorize member"))
            }
            state.sharedMembers
                .filter { it.optString("vaultId") == selected }
                .forEach { value ->
                    Row {
                        Text(
                            value.optString("userPublicKey").take(18) +
                                "… · " +
                                value.optString("role"),
                            Modifier.weight(1f),
                        )
                        if (value.optString("role") != "owner")
                            TextButton(
                                onClick = {
                                    run {
                                        vault.command(
                                            "remove-member",
                                            JSONObject()
                                                .put("vaultId", selected)
                                                .put("publicKey", value.optString("userPublicKey")),
                                        )
                                    }
                                }
                            ) {
                                Text(t("撤销", "Revoke"))
                            }
                    }
                }
        }
        HorizontalDivider()
        Row {
            Text(t("允许已授权成员连接", "Allow authorized members to connect"), Modifier.weight(1f))
            Switch(endpoint.isNotEmpty(), { if (it) vault.sync.start() else vault.sync.stop() })
        }
        if (endpoint.isNotEmpty()) {
            Text(endpoint)
            Text(
                "${t("附近设备", "Nearby devices")}: ${peers.size}",
                style = MaterialTheme.typography.bodySmall,
            )
            TextButton(
                enabled = selected.isNotEmpty(),
                onClick = {
                    val invite =
                        android.net.Uri.Builder()
                            .scheme("passwordvault")
                            .authority("join")
                            .appendQueryParameter("version", "2")
                            .appendQueryParameter("endpoint", endpoint)
                            .appendQueryParameter("key", publicKey)
                            .appendQueryParameter("vault", selected)
                            .build()
                            .toString()
                    vault.copy(invite)
                },
            ) {
                Text(t("复制邀请", "Copy invitation"))
            }
        }
        Input("passwordvault://join?…", join, { join = it })
        Button(
            enabled = !busy && join.isNotBlank(),
            onClick = {
                run {
                    val uri = android.net.Uri.parse(join)
                    require(
                        uri.scheme == "passwordvault" &&
                            uri.host == "join" &&
                            uri.getQueryParameter("version") == "2"
                    )
                    require(uri.queryParameterNames.all { uri.getQueryParameters(it).size == 1 })
                    val peer = uri.getQueryParameter("key") ?: error("Missing key")
                    val id = uri.getQueryParameter("vault") ?: error("Missing vault")
                    val target = uri.getQueryParameter("endpoint") ?: error("Missing endpoint")
                    val packet =
                        vault.command(
                            "sync-request",
                            JSONObject().put("peerKey", peer).put("vaultId", id),
                        )
                    val response = LocalSync.exchange(target, packet)
                    vault.command(
                        "sync-apply",
                        JSONObject().put("packet", response).put("peerKey", peer).put("vaultId", id),
                    )
                    selected = id
                    message = t("同步完成", "Sync complete")
                }
            },
        ) {
            Text(t("连接并同步", "Connect and sync"))
        }
        if (busy) LinearProgressIndicator(Modifier.fillMaxWidth())
        message?.let { Text(it) }
        Text(
            t("锁定或切后台会停止共享。", "Sharing stops when locked or backgrounded."),
            style = MaterialTheme.typography.bodySmall,
        )
    }
}
