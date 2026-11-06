package com.securepass.vault

import android.app.PendingIntent
import android.content.Intent
import android.os.Bundle
import android.view.WindowManager
import androidx.activity.compose.setContent
import androidx.annotation.RequiresApi
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import androidx.credentials.*
import androidx.credentials.provider.*
import androidx.fragment.app.FragmentActivity
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeout
import kotlinx.coroutines.flow.first
import okhttp3.OkHttpClient
import okhttp3.Request
import org.json.JSONArray
import org.json.JSONObject
import java.security.MessageDigest
import java.util.Base64
import java.net.URI

@RequiresApi(34)
class PasskeyProviderActivity : FragmentActivity() {
    private val vault get() = (application as VaultApplication).vault
    private var generation=0
    private var failureContext="请求无效 / Invalid request"
    override fun onDestroy() { generation++; super.onDestroy() }
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
        val createRequest = PendingIntentHandler.retrieveProviderCreateCredentialRequest(intent)
        val getRequest = PendingIntentHandler.retrieveProviderGetCredentialRequest(intent)
        val callerLabel = createRequest?.callingAppInfo?.packageName ?: getRequest?.callingAppInfo?.packageName ?: "PasswordVault"
        val requestLabel = runCatching {
            val creation=createRequest?.callingRequest as? CreatePublicKeyCredentialRequest
            val assertion=getRequest?.credentialOptions?.filterIsInstance<GetPublicKeyCredentialOption>()?.singleOrNull()
            val body=JSONObject(creation?.requestJson ?: assertion?.requestJson ?: "{}")
            if(creation!=null) body.getJSONObject("rp").getString("id") + " · " + body.getJSONObject("user").getString("name") else body.optString("rpId")
        }.getOrDefault("")
        setContent {
            var secret by remember { mutableStateOf("") }
            var busy by remember { mutableStateOf(false) }
            var error by remember { mutableStateOf<String?>(null) }
            val scope=rememberCoroutineScope()
            MaterialTheme { Surface(Modifier.fillMaxSize()) { Column(Modifier.safeDrawingPadding().padding(24.dp),verticalArrangement=Arrangement.spacedBy(16.dp)) {
                Text("PasswordVault · Passkey",style=MaterialTheme.typography.headlineMedium)
                Text(callerLabel)
                Text(requestLabel)
                if (intent.getStringExtra("mode")=="create") Text("保存到个人资料库 / Save to personal vault")
                Text("确认请求并输入主密码 / Confirm and verify with your master password")
                OutlinedTextField(value=secret,onValueChange={secret=it},singleLine=true,keyboardOptions=KeyboardOptions(keyboardType=KeyboardType.Password,autoCorrectEnabled=false),visualTransformation=PasswordVisualTransformation(),label={Text("主密码 / Master password")})
                error?.let { Text(it,color=MaterialTheme.colorScheme.error) }
                Button(enabled=!busy && secret.isNotEmpty(),onClick={busy=true;scope.launch { try { execute(secret) } catch (failure:Exception) {error=failureContext;if(BuildConfig.DEBUG)android.util.Log.w("PasswordVaultPasskey","Request failed: "+failureContext+" ("+failure.javaClass.simpleName+")")} finally {secret="";busy=false} }}) {Text("确认 / Confirm")}
                TextButton(onClick={generation++;secret="";setResult(RESULT_CANCELED);finish()}) {Text("取消 / Cancel")}
            } } }
        }
    }
    private suspend fun execute(secret:String) {
        val own=generation
        failureContext="无法打开资料库 / Could not open vault"
        withTimeout(15000) { vault.state.first { it.ready } }
        check(generation==own && !isFinishing)
        failureContext="主密码不正确或资料库已锁定 / Incorrect master password or locked vault"
        if(!vault.state.value.unlocked) vault.authenticate(secret,false)
        check(vault.state.value.unlocked && generation==own && !isFinishing)
        if(intent.getStringExtra("mode")=="discover") { discover();return }
        failureContext="凭据请求参数不受支持 / Unsupported credential request"
        val create=PendingIntentHandler.retrieveProviderCreateCredentialRequest(intent)
        val get=PendingIntentHandler.retrieveProviderGetCredentialRequest(intent)
        val creating=create!=null
        val request=create?.callingRequest as? CreatePublicKeyCredentialRequest
        val option=get?.credentialOptions?.filterIsInstance<GetPublicKeyCredentialOption>()?.singleOrNull()
        val json=JSONObject(request?.requestJson ?: option?.requestJson ?: error("Missing request"))
        val caller=create?.callingAppInfo ?: get?.callingAppInfo ?: error("Missing caller")
        val rp=if(creating)json.getJSONObject("rp").getString("id") else json.getString("rpId")
        failureContext="应用与网站关联验证失败，请检查网络和网站配置 / App-to-site association could not be verified"
        val origin=verifyCaller(caller,rp)
        failureContext="请求参数不受支持 / Unsupported request parameters"
        val challenge=json.getString("challenge")
        val challengeBytes=Base64.getUrlDecoder().decode(challenge)
        check(challengeBytes.size in 16..1024 && encode(challengeBytes)==challenge)
        check(!json.has("extensions") || json.getJSONObject("extensions").length()==0)
        val clientData=JSONObject().put("type",if(creating)"webauthn.create" else "webauthn.get").put("origin",origin).put("challenge",challenge).put("crossOrigin",false).toString()
        val suppliedHash = request?.clientDataHash ?: option?.clientDataHash
        val browser = origin.startsWith("https://")
        val hash = if (browser) suppliedHash?.also { check(it.size == 32) } ?: error("Missing browser hash")
          else { check(suppliedHash == null); MessageDigest.getInstance("SHA-256").digest(clientData.toByteArray()) }
        val query=JSONObject().put("rpId",rp).put("clientDataHash",encode(hash)).put("currentPassword",secret)
        if(creating) {
            query.put("library", "")
            check(json.getJSONArray("pubKeyCredParams").objects().any{it.optInt("alg")==-7 && it.optString("type")=="public-key"})
            check(json.optString("attestation","none")=="none")
            query.put("userHandle",json.getJSONObject("user").getString("id")).put("userName",json.getJSONObject("user").getString("name"))
            query.put("excluded",JSONArray(json.optJSONArray("excludeCredentials")?.objects()?.map{it.getString("id")}?:emptyList<String>()))
        } else {
            val id=intent.getStringExtra("credentialId") ?: error("No selected credential")
            query.put("itemId",intent.getStringExtra("itemId")).put("credentialId",id).put("library",intent.getStringExtra("library") ?: "")
            query.put("allowed",JSONArray(json.optJSONArray("allowCredentials")?.objects()?.map{it.getString("id")}?:emptyList<String>()))
        }
        check(generation==own && !isFinishing)
        failureContext="无法验证主密码或处理此凭证 / Could not verify the master password or process this credential"
        val response=vault.command(if(creating)"passkey-system-create" else "passkey-system-assert",query)
        query.remove("currentPassword")
        check(generation==own && !isFinishing)
        val body=JSONObject().put("clientDataJSON",encode((if(browser) "{}" else clientData).toByteArray()))
        if(creating)body.put("attestationObject",response.getString("attestationObject")).put("transports",JSONArray().put("internal"))
        else body.put("authenticatorData",response.getString("authenticatorData")).put("signature",response.getString("signature")).put("userHandle",response.getString("userHandle"))
        val result=JSONObject().put("id",response.getString("id")).put("rawId",response.getString("id")).put("type","public-key").put("response",body).put("clientExtensionResults",JSONObject()).toString()
        val reply=Intent()
        if(creating)PendingIntentHandler.setCreateCredentialResponse(reply,CreatePublicKeyCredentialResponse(result))
        else PendingIntentHandler.setGetCredentialResponse(reply,GetCredentialResponse(PublicKeyCredential(result)))
        setResult(RESULT_OK,reply);finish()
    }
    private suspend fun discover() {
        val request=PendingIntentHandler.retrieveBeginGetCredentialRequest(intent) ?: error("No discovery")
        val entries=mutableListOf<CredentialEntry>()
        for(option in request.beginGetCredentialOptions.filterIsInstance<BeginGetPublicKeyCredentialOption>()) {
            val rp=JSONObject(option.requestJson).getString("rpId")
            failureContext="应用与网站关联验证失败 / App-to-site association could not be verified"
            verifyCaller(request.callingAppInfo ?: error("Missing authenticated caller"),rp)
            val keys=vault.command("passkey-index").getJSONArray("passkeys").objects()
            for(key in keys) {
                if(key.optString("rpId")!=rp)continue
                val next=Intent(this,PasskeyProviderActivity::class.java).putExtra("mode","get").putExtra("itemId",key.getString("itemId")).putExtra("credentialId",key.getString("id")).putExtra("library",key.optString("library"))
                val pending=PendingIntent.getActivity(this,AndroidCredentialProvider.ids.incrementAndGet(),next,PendingIntent.FLAG_MUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
                entries.add(PublicKeyCredentialEntry(this,key.optString("userName").ifEmpty{"Passkey"},pending,option))
            }
        }
        val reply=Intent();PendingIntentHandler.setBeginGetCredentialResponse(reply,BeginGetCredentialResponse(credentialEntries=entries));setResult(RESULT_OK,reply);finish()
    }
    private suspend fun verifyCaller(caller:CallingAppInfo,rp:String):String=withContext(Dispatchers.IO) {
        // Pinned Google privileged-caller list, restricted to release Chrome/Edge certificates.
        val allowlist = assets.open("passkey-browser-allowlist.json").bufferedReader().use { it.readText() }
        val forwarded = caller.getOrigin(allowlist)
        if (forwarded != null) {
            val page=URI(forwarded)
            check(page.scheme=="https" && (page.host==rp || page.host?.endsWith("."+rp)==true) && page.userInfo==null && (page.path.isNullOrEmpty() || page.path=="/") && page.query==null && page.fragment==null)
            return@withContext forwarded
        }
        val url=URI("https://$rp/.well-known/assetlinks.json")
        check(url.host==rp && !rp.contains(':') && rp.contains('.') && !rp.all{it.isDigit() || it=='.'} && url.userInfo==null)
        val signers=caller.signingInfo.apkContentsSigners.map { MessageDigest.getInstance("SHA-256").digest(it.toByteArray()) }
        check(signers.isNotEmpty())
        val http=OkHttpClient.Builder().followRedirects(false).followSslRedirects(false).callTimeout(java.time.Duration.ofSeconds(10)).build()
        val links=http.newCall(Request.Builder().url(url.toString()).build()).execute().use { response ->
            check(response.isSuccessful); val body=response.body ?: error("No links");check(body.contentLength()<=262144); val source=body.source();source.request(262145);val bytes=source.buffer.readByteArray();check(bytes.size<=262144);JSONArray(String(bytes))
        }
        val fingerprints=links.objects().filter { link ->
            link.optJSONArray("relation")?.let{(0 until it.length()).any{index->it.optString(index)=="delegate_permission/common.get_login_creds"}}==true && link.optJSONObject("target")?.optString("namespace")=="android_app" && link.optJSONObject("target")?.optString("package_name")==caller.packageName
        }.flatMap { link -> val values=link.getJSONObject("target").getJSONArray("sha256_cert_fingerprints");(0 until values.length()).map{values.getString(it).replace(":","").uppercase()} }
        check(signers.all{bytes->bytes.joinToString(""){"%02X".format(it)} in fingerprints})
        "android:apk-key-hash:"+encode(signers.first())
    }
    private fun encode(bytes:ByteArray)=Base64.getUrlEncoder().withoutPadding().encodeToString(bytes)
}
