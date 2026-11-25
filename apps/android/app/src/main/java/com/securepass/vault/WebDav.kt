package com.securepass.vault

import com.securepass.vault.core.webdavDownload
import com.securepass.vault.core.webdavList
import com.securepass.vault.core.webdavParseListing
import com.securepass.vault.core.webdavUpload
import java.text.SimpleDateFormat
import java.util.Locale
import java.util.concurrent.TimeUnit
import okhttp3.Credentials
import okhttp3.HttpUrl
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONArray
import org.json.JSONObject

data class RemoteBackup(val url: HttpUrl, val name: String, val modified: Long?, val size: Long?)

/**
 * WebDAV backup client backed by `vault-core`'s shared HTTPS client and RFC 4918 XML parser.
 * An optional custom [transport] is retained only for self-signed MockWebServer tests.
 */
class WebDav(
    url: String,
    username: String,
    password: String,
    folder: String,
    private val transport: OkHttpClient? = null,
) : AutoCloseable {
    private val client: OkHttpClient? =
        transport?.newBuilder()
            ?.followRedirects(false)
            ?.followSslRedirects(false)
            ?.connectTimeout(30, TimeUnit.SECONDS)
            ?.readTimeout(60, TimeUnit.SECONDS)
            ?.callTimeout(90, TimeUnit.SECONDS)
            ?.build()
    private val auth = Credentials.basic(username, password)
    private val base: HttpUrl
    private val configJson: String

    init {
        val root = url.toHttpUrl()
        require(root.isHttps && root.username.isEmpty() && root.password.isEmpty())
        require(!folder.startsWith("/") && !folder.split('/').contains(".."))
        base =
            root
                .newBuilder()
                .addPathSegments(folder.trim('/'))
                .addPathSegment("")
                .query(null)
                .fragment(null)
                .build()
        configJson =
            JSONObject()
                .put("url", url)
                .put("username", username)
                .put("password", password)
                .put("folder", folder)
                .put("strictHrefs", false)
                .toString()
    }

    private fun allowed(url: HttpUrl) =
        url.scheme == base.scheme &&
            url.host == base.host &&
            url.port == base.port &&
            url.encodedPath.startsWith(base.encodedPath) &&
            url.query == null &&
            url.fragment == null

    private fun requestWithTransport(method: String, url: HttpUrl, body: ByteArray? = null): ByteArray {
        val http = requireNotNull(client)
        var target = url
        repeat(5) {
            require(allowed(target))
            val request =
                Request.Builder()
                    .url(target)
                    .header("Authorization", auth)
                    .apply {
                        if (method == "PROPFIND") header("Depth", "1")
                        if (method == "PUT") header("If-None-Match", "*")
                    }
                    .method(
                        method,
                        if (method in listOf("GET", "HEAD")) null
                        else
                            (body ?: byteArrayOf()).toRequestBody(
                                (if (method == "PROPFIND") "application/xml"
                                    else "application/octet-stream")
                                    .toMediaType()
                            ),
                    )
                    .build()
            http.newCall(request).execute().use { response ->
                if (response.code in 300..399) {
                    target =
                        target.resolve(response.header("Location") ?: error("Invalid redirect"))
                            ?: error("Invalid redirect")
                    require(allowed(target))
                    return@repeat
                }
                require(response.isSuccessful || method == "MKCOL" && response.code == 405) {
                    "WebDAV request failed"
                }
                val source = response.body?.source() ?: error("Empty response")
                val out = java.io.ByteArrayOutputStream()
                val buffer = ByteArray(8192)
                while (true) {
                    val count = source.read(buffer)
                    if (count < 0) break
                    require(out.size() + count <= 64 * 1024 * 1024)
                    out.write(buffer, 0, count)
                }
                return out.toByteArray()
            }
        }
        error("Too many redirects")
    }

    private fun parseDateMillis(value: String?): Long? {
        if (value.isNullOrBlank()) return null
        return runCatching {
                SimpleDateFormat("EEE, dd MMM yyyy HH:mm:ss zzz", Locale.US).parse(value)?.time
            }
            .getOrNull()
            ?: runCatching { java.time.Instant.parse(value).toEpochMilli() }.getOrNull()
    }

    private fun decodeListingJson(json: String): List<RemoteBackup> {
        val rows = JSONArray(json)
        val result = mutableListOf<RemoteBackup>()
        for (i in 0 until rows.length()) {
            val row = rows.getJSONObject(i)
            val url = row.getString("url").toHttpUrl()
            val name = row.getString("name")
            val modified =
                parseDateMillis(row.optString("modified").ifEmpty { null })
                    ?: parseDateMillis(row.optString("created").ifEmpty { null })
                    ?: Regex(
                            "(?:backup_enc_|backup_|PasswordVault-)(\\d{10}|\\d{13})(?:-[0-9a-fA-F]{8})?\\..*"
                        )
                        .matchEntire(name)
                        ?.groupValues
                        ?.get(1)
                        ?.let { it.toLongOrNull()?.times(if (it.length == 10) 1000 else 1) }
            val size = if (row.isNull("size")) null else row.optLong("size").takeIf { it >= 0 }
            result.add(RemoteBackup(url, name, modified, size))
        }
        return result.distinctBy { it.url }.sortedByDescending { it.modified ?: 0 }
    }

    fun list(): List<RemoteBackup> {
        val json =
            if (transport == null) {
                webdavList(configJson)
            } else {
                val body =
                    """<d:propfind xmlns:d="DAV:"><d:prop><d:getlastmodified/><d:creationdate/><d:getcontentlength/><d:resourcetype/></d:prop></d:propfind>"""
                        .toByteArray()
                val data = requestWithTransport("PROPFIND", base, body)
                require(data.size <= 8 * 1024 * 1024)
                webdavParseListing(base.toString(), data.toString(Charsets.UTF_8), false)
            }
        return decodeListingJson(json)
    }

    fun download(file: RemoteBackup): ByteArray =
        if (transport == null) webdavDownload(configJson, file.url.toString())
        else requestWithTransport("GET", file.url)

    fun upload(bytes: ByteArray) {
        val name =
            "PasswordVault-${System.currentTimeMillis()}-${java.util.UUID.randomUUID().toString().take(8)}.pvbackup"
        if (transport == null) {
            webdavUpload(configJson, name, bytes)
        } else {
            requestWithTransport("MKCOL", base)
            requestWithTransport("PUT", base.newBuilder().addPathSegment(name).build(), bytes)
        }
    }

    override fun close() {
        client?.dispatcher?.cancelAll()
        client?.connectionPool?.evictAll()
        client?.dispatcher?.executorService?.shutdown()
    }
}
