package com.securepass.vault

import android.content.Intent
import android.os.Bundle
import android.service.autofill.Dataset
import android.view.WindowManager
import android.view.autofill.AutofillManager
import android.view.autofill.AutofillValue
import android.widget.RemoteViews
import androidx.activity.compose.setContent
import androidx.annotation.RequiresApi
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.fragment.app.FragmentActivity
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import kotlinx.coroutines.launch
import org.json.JSONObject

@RequiresApi(26)
class AutofillActivity : FragmentActivity() {
    private val vault
        get() = (application as VaultApplication).vault

    private var token = ""

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
        token = intent.getStringExtra("token") ?: return finish()
        val target = FillRequests.get(token) ?: return finish()
        setContent {
            val state by vault.state.collectAsStateWithLifecycle()
            val scope = rememberCoroutineScope()
            var confirm by remember { mutableStateOf<JSONObject?>(null) }
            var query by remember { mutableStateOf("") }
            LaunchedEffect(state.unlocked) {
                if (!state.unlocked) {
                    confirm = null
                    query = ""
                }
            }
            MaterialTheme {
                Surface(Modifier.fillMaxSize()) {
                    if (!state.unlocked) UnlockScreen(vault, state, { zh, _ -> zh }, true, {})
                    else
                        Column(
                            Modifier.safeDrawingPadding().padding(20.dp),
                            verticalArrangement = Arrangement.spacedBy(16.dp),
                        ) {
                            Text("PasswordVault", style = MaterialTheme.typography.headlineMedium)
                            Text("目标应用 / App: ${target.packageName}")
                            target.domain?.let { Text("页面声明的网站 / Reported site: $it") }
                            Text(
                                "确认目标后再选择账号。不会自动提交登录。\nConfirm the destination before choosing. The form is never submitted automatically.",
                                style = MaterialTheme.typography.bodySmall,
                            )
                            if (target.savePassword != null) {
                                Text("保存登录信息 / Save credentials: ${target.saveUser.orEmpty()}")
                                Button(
                                    onClick = {
                                        scope.launch {
                                            if (FillRequests.get(token) == null)
                                                return@launch finish()
                                            val item =
                                                VaultRepository.blank("password")
                                                    .put(
                                                        "title",
                                                        target.domain ?: target.packageName,
                                                    )
                                                    .put("username", target.saveUser.orEmpty())
                                                    .put("password", target.savePassword)
                                            // A WebView's claimed domain is not trusted as an
                                            // association. Require an explicit website edit later.
                                            item
                                                .put("androidPackage", target.packageName)
                                                .put(
                                                    "androidSigningCertSha256",
                                                    signingHash(target.packageName),
                                                )
                                            if (vault.save(item)) finish()
                                        }
                                    }
                                ) {
                                    Text("保存到资料库 / Save")
                                }
                            } else {
                                Input("搜索账号 / Search", query, { query = it })
                                val candidates =
                                    state.entries.flatMap { parent ->
                                        listOf(parent) +
                                            parent
                                                .optJSONArray("accounts")
                                                ?.objects()
                                                .orEmpty()
                                                .map { account ->
                                                    JSONObject(parent.toString())
                                                        .put("accountId", account.optString("id"))
                                                        .put(
                                                            "username",
                                                            account.optString("username"),
                                                        )
                                                }
                                    }
                                val entries =
                                    candidates.filter {
                                        !it.optBoolean("isDeleted") &&
                                            it.optString("type") == "password" &&
                                            (it.optString("title").contains(query, true) ||
                                                it.optString("username").contains(query, true))
                                    }
                                LazyColumn(Modifier.weight(1f)) {
                                    items(
                                        entries,
                                        key = {
                                            it.optString("id") + ":" + it.optString("accountId")
                                        },
                                    ) { item ->
                                        TextButton(
                                            onClick = { confirm = item },
                                            modifier = Modifier.fillMaxWidth(),
                                        ) {
                                            Column(Modifier.fillMaxWidth()) {
                                                Text(item.optString("title"))
                                                Text(item.optString("username"))
                                            }
                                        }
                                    }
                                }
                                TextButton(onClick = ::finish) { Text("取消 / Cancel") }
                                state.error?.let {
                                    Text(it, color = MaterialTheme.colorScheme.error)
                                }
                            }
                            if (state.unlocked)
                                confirm?.let { entry ->
                                    AlertDialog(
                                        onDismissRequest = { confirm = null },
                                        title = { Text("向此应用填入？ / Fill this app?") },
                                        text = {
                                            Text(
                                                "${target.packageName}\n${target.domain.orEmpty()}\n\n${entry.optString("title")} · ${entry.optString("username")}"
                                            )
                                        },
                                        confirmButton = {
                                            TextButton(onClick = { complete(entry, target) }) {
                                                Text("确认填入 / Fill")
                                            }
                                        },
                                        dismissButton = {
                                            TextButton(onClick = { confirm = null }) {
                                                Text("取消 / Cancel")
                                            }
                                        },
                                    )
                                }
                        }
                }
            }
        }
    }

    private fun signingHash(packageName: String): String {
        val info =
            packageManager.getPackageInfo(
                packageName,
                if (android.os.Build.VERSION.SDK_INT >= 28)
                    android.content.pm.PackageManager.GET_SIGNING_CERTIFICATES
                else android.content.pm.PackageManager.GET_SIGNATURES,
            )
        val cert =
            if (android.os.Build.VERSION.SDK_INT >= 28)
                info.signingInfo?.apkContentsSigners?.firstOrNull()
            else info.signatures?.firstOrNull()
        return cert
            ?.let {
                java.security.MessageDigest.getInstance("SHA-256")
                    .digest(it.toByteArray())
                    .joinToString("") { byte -> "%02x".format(byte) }
            }
            .orEmpty()
    }

    private fun complete(entry: JSONObject, target: FillTarget) {
        if (FillRequests.get(token) != target || !vault.state.value.unlocked) return finish()
        val fresh =
            vault.state.value.entries.firstOrNull {
                it.optString("id") == entry.optString("id") && !it.optBoolean("isDeleted")
            } ?: return finish()
        val account =
            if (entry.optString("accountId").isNotEmpty())
                fresh.optJSONArray("accounts")?.objects()?.firstOrNull {
                    it.optString("id") == entry.optString("accountId")
                } ?: return finish()
            else fresh
        val presentation =
            RemoteViews(packageName, android.R.layout.simple_list_item_1).apply {
                setTextViewText(android.R.id.text1, "PasswordVault")
            }
        val dataset =
            Dataset.Builder(presentation)
                .setValue(target.passwordId, AutofillValue.forText(account.optString("password")))
        target.userId?.let {
            dataset.setValue(it, AutofillValue.forText(account.optString("username")))
        }

        setResult(
            RESULT_OK,
            Intent().putExtra(AutofillManager.EXTRA_AUTHENTICATION_RESULT, dataset.build()),
        )
        finish()
    }

    override fun onDestroy() {
        FillRequests.remove(token)
        super.onDestroy()
    }

    override fun onStop() {
        super.onStop()
        if (!isChangingConfigurations) vault.lock()
    }
}
