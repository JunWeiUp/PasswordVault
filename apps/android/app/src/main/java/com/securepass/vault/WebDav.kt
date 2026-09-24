package com.securepass.vault

import android.util.Xml
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
import org.xmlpull.v1.XmlPullParser

data class RemoteBackup(val url: HttpUrl, val name: String, val modified: Long?, val size: Long?)

class WebDav(
    url: String,
    username: String,
    password: String,
    folder: String,
    transport: OkHttpClient? = null,
) : AutoCloseable {
    private val client =
        (transport ?: OkHttpClient())
            .newBuilder()
            .followRedirects(false)
            .followSslRedirects(false)
            .connectTimeout(30, TimeUnit.SECONDS)
            .readTimeout(60, TimeUnit.SECONDS)
            .callTimeout(90, TimeUnit.SECONDS)
            .build()
    private val auth = Credentials.basic(username, password)
    private val base: HttpUrl

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
    }

    private fun allowed(url: HttpUrl) =
        url.scheme == base.scheme &&
            url.host == base.host &&
            url.port == base.port &&
            url.encodedPath.startsWith(base.encodedPath) &&
            url.query == null &&
            url.fragment == null

    private fun request(method: String, url: HttpUrl, body: ByteArray? = null): ByteArray {
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
            client.newCall(request).execute().use { response ->
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

    fun list(): List<RemoteBackup> {
        val body =
            """<d:propfind xmlns:d="DAV:"><d:prop><d:getlastmodified/><d:creationdate/><d:getcontentlength/><d:resourcetype/></d:prop></d:propfind>"""
                .toByteArray()
        val data = request("PROPFIND", base, body)
        require(data.size <= 8 * 1024 * 1024)
        val xml = data.toString(Charsets.UTF_8)
        require(!xml.contains("<!DOCTYPE", true) && !xml.contains("<!ENTITY", true))
        val parser = Xml.newPullParser()
        parser.setFeature(XmlPullParser.FEATURE_PROCESS_NAMESPACES, true)
        parser.setInput(xml.reader())
        var href = ""
        var modified: Long? = null
        var size: Long? = null
        var collection = false
        var propDate: Long? = null
        var propCreated: Long? = null
        var hasModification = false
        var propSize: Long? = null
        var propCollection = false
        var status = ""
        var responseStatus = ""
        var inProp = false
        var goodProp = false
        val result = mutableListOf<RemoteBackup>()
        while (parser.eventType != XmlPullParser.END_DOCUMENT) {
            val tag = parser.name.orEmpty()
            if (parser.eventType == XmlPullParser.START_TAG)
                when (tag) {
                    "response" -> {
                        href = ""
                        modified = null
                        size = null
                        collection = false
                        responseStatus = ""
                        hasModification = false
                        goodProp = false
                    }
                    "propstat" -> {
                        propDate = null
                        propCreated = null
                        propSize = null
                        propCollection = false
                        status = ""
                        inProp = true
                    }
                    "href" -> href = parser.nextText()
                    "status" -> {
                        val text = parser.nextText()
                        if (inProp) status = text else responseStatus = text
                    }
                    "getlastmodified" ->
                        propDate =
                            runCatching {
                                    SimpleDateFormat("EEE, dd MMM yyyy HH:mm:ss zzz", Locale.US)
                                        .parse(parser.nextText())
                                        ?.time
                                }
                                .getOrNull()
                    "creationdate" -> {
                        val value = parser.nextText()
                        propCreated =
                            runCatching { java.time.Instant.parse(value).toEpochMilli() }
                                .getOrNull()
                    }
                    "getcontentlength" ->
                        propSize = parser.nextText().toLongOrNull()?.takeIf { it >= 0 }
                    "collection" -> propCollection = true
                }
            if (parser.eventType == XmlPullParser.END_TAG)
                when (tag) {
                    "propstat" -> {
                        inProp = false
                        if (Regex("HTTP/\\S+ 2\\d\\d.*").matches(status.trim())) {
                            goodProp = true
                            if (propDate != null) {
                                modified = propDate
                                hasModification = true
                            } else if (!hasModification) modified = propCreated ?: modified
                            size = propSize ?: size
                            collection = collection || propCollection
                        }
                    }
                    "response" -> {
                        val url = base.resolve(href)
                        if (
                            url != null &&
                                allowed(url) &&
                                goodProp &&
                                (responseStatus.isBlank() ||
                                    Regex("HTTP/\\S+ 2\\d\\d.*").matches(responseStatus.trim())) &&
                                !collection &&
                                url != base
                        ) {
                            val name = url.pathSegments.last()
                            if (name.endsWith(".json", true) || name.endsWith(".pvbackup", true)) {
                                val inferred =
                                    Regex(
                                            "(?:backup_enc_|backup_|PasswordVault-)(\\d{10}|\\d{13})(?:-[0-9a-fA-F]{8})?\\..*"
                                        )
                                        .matchEntire(name)
                                        ?.groupValues
                                        ?.get(1)
                                        ?.let {
                                            it.toLongOrNull()
                                                ?.times(if (it.length == 10) 1000 else 1)
                                        }
                                result.add(RemoteBackup(url, name, modified ?: inferred, size))
                            }
                        }
                    }
                }
            parser.next()
        }
        return result.distinctBy { it.url }.sortedByDescending { it.modified ?: 0 }
    }

    fun download(file: RemoteBackup) = request("GET", file.url)

    fun upload(bytes: ByteArray) {
        request("MKCOL", base)
        request(
            "PUT",
            base
                .newBuilder()
                .addPathSegment(
                    "PasswordVault-${System.currentTimeMillis()}-${java.util.UUID.randomUUID().toString().take(8)}.pvbackup"
                )
                .build(),
            bytes,
        )
    }

    override fun close() {
        client.dispatcher.cancelAll()
        client.connectionPool.evictAll()
        client.dispatcher.executorService.shutdown()
    }
}
