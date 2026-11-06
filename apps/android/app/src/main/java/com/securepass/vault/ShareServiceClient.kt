package com.securepass.vault

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONObject
import java.util.concurrent.TimeUnit

internal class ShareServiceClient(endpoint: String, private val token: String) {
    private val base = endpoint.toHttpUrl()
    init {
        require(base.isHttps || (base.scheme == "http" && base.host in listOf("localhost", "127.0.0.1", "::1")))
        require(base.username.isEmpty() && base.password.isEmpty() && base.query == null && base.fragment == null && base.encodedPath == "/" && token.length >= 32)
    }
    suspend fun capabilities() = send("api/capabilities", "GET")
    suspend fun list() = send("api/shares", "GET")
    suspend fun revoke(id: String) { require(id.matches(Regex("[a-f0-9]{32}"))); send("api/shares/$id", "DELETE") }
    suspend fun create(envelope: JSONObject, expiresIn: Int, email: String?): String {
        val id = envelope.getString("id")
        val key = envelope.getString("key")
        require(id.matches(Regex("[a-f0-9]{32}")) && key.matches(Regex("[A-Za-z0-9_-]{43}")))
        require(expiresIn in listOf(3600, 86400, 604800, 2592000))
        val body = JSONObject(envelope.toString()).apply { remove("key"); put("expiresIn", expiresIn); if (!email.isNullOrBlank()) put("recipientEmail", email) }
        require(send("api/shares", "POST", body).getString("id") == id)
        return base.newBuilder().addPathSegments("s/$id").fragment(key).build().toString()
    }
    private suspend fun send(path: String, method: String, body: JSONObject? = null): JSONObject = withContext(Dispatchers.IO) {
        val client = OkHttpClient.Builder().followRedirects(false).followSslRedirects(false).callTimeout(30, TimeUnit.SECONDS).build()
        try {
            val request = Request.Builder().url(base.newBuilder().addPathSegments(path).build())
                .header("Authorization", "Bearer $token").header("Cache-Control", "no-store")
                .method(method, body?.toString()?.toRequestBody("application/json".toMediaType())).build()
            client.newCall(request).execute().use { response ->
                check(response.isSuccessful) { "Share request failed (${response.code})" }
                val data = java.io.ByteArrayOutputStream()
                response.body?.byteStream()?.use { input ->
                    val buffer = ByteArray(8192)
                    while (true) {
                        val count = input.read(buffer); if (count < 0) break
                        require(data.size() + count <= 1024 * 1024)
                        data.write(buffer, 0, count)
                    }
                } ?: error("Missing share response")
                JSONObject(data.toString("UTF-8"))
            }
        } finally { client.connectionPool.evictAll(); client.dispatcher.executorService.shutdown() }
    }
}
