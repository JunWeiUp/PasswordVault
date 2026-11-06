package com.securepass.vault

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.launch
import org.json.JSONArray
import org.json.JSONObject

@Composable
internal fun PasskeyRecordsPanel(item: JSONObject, vault: VaultRepository, t: (String, String) -> String, onRemoved: (String) -> Unit = {}) {
    val keys = item.optJSONArray("passkeys") ?: JSONArray()
    if (keys.length() == 0) return
    val scope = rememberCoroutineScope()
    var selected by remember { mutableStateOf<String?>(null) }
    var currentPassword by remember { mutableStateOf("") }
    var busy by remember { mutableStateOf(false) }; var error by remember { mutableStateOf("") }
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text("Passkeys", style = MaterialTheme.typography.titleMedium)
        for (index in 0 until keys.length()) {
            val key = keys.getJSONObject(index)
            Text(key.optString("rpId")); Text(key.optString("userName"))
            SelectionContainer { Text(key.optString("credentialId"), style = MaterialTheme.typography.bodySmall) }
            TextButton(enabled = vault.canEdit(item), onClick = { selected = key.optString("credentialId"); currentPassword = ""; error = "" }) { Text(t("删除通行密钥…", "Delete Passkey…")) }
        }
    }
    if (selected != null) AlertDialog(onDismissRequest = { if (!busy) { selected = null; currentPassword = "" } }, title = { Text(t("删除此通行密钥？", "Delete this Passkey?")) }, text = {
        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Text(t("请确认网站仍有其他登录方式；删除资料库凭证不会自动撤销网站注册。", "Ensure another sign-in method exists; deleting the vault credential does not revoke its website registration."))
            OutlinedTextField(currentPassword, { currentPassword = it }, label = { Text(t("当前主密码", "Current master password")) }, visualTransformation = PasswordVisualTransformation(), modifier = Modifier.fillMaxWidth())
            if (error.isNotEmpty()) Text(error, color = MaterialTheme.colorScheme.error)
        }
    }, confirmButton = { TextButton(enabled = !busy && currentPassword.isNotEmpty(), onClick = { scope.launch {
        busy = true
        try { vault.command("passkey-remove", JSONObject().put("itemId", item.getString("id")).put("credentialId", selected).put("currentPassword", currentPassword)); vault.refresh(); selected?.let(onRemoved); selected = null }
        catch (_: Exception) { error = t("未能删除，请检查主密码后重试", "Could not delete; verify the master password and retry") }
        finally { busy = false; currentPassword = "" }
    } }) { Text(t("确认删除", "Delete")) } }, dismissButton = { TextButton(enabled = !busy, onClick = { selected = null; currentPassword = "" }) { Text(t("取消", "Cancel")) } })
}
