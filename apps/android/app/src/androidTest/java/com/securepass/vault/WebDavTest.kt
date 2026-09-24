package com.securepass.vault

import androidx.test.ext.junit.runners.AndroidJUnit4
import java.util.concurrent.TimeUnit
import okhttp3.OkHttpClient
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.tls.HandshakeCertificates
import okhttp3.tls.HeldCertificate
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class WebDavTest {
    @Test
    fun metadataAndRedirectBoundary() {
        val certificate = HeldCertificate.Builder().addSubjectAlternativeName("localhost").build()
        val serverTLS = HandshakeCertificates.Builder().heldCertificate(certificate).build()
        val clientTLS =
            HandshakeCertificates.Builder().addTrustedCertificate(certificate.certificate).build()
        val server = MockWebServer()
        server.useHttps(serverTLS.sslSocketFactory(), false)
        server.start()
        val transport =
            OkHttpClient.Builder()
                .sslSocketFactory(clientTLS.sslSocketFactory(), clientTLS.trustManager)
                .build()
        try {
            val xml =
                """<d:multistatus xmlns:d="DAV:">
        <d:response><d:href>/dav/good.pvbackup</d:href><d:propstat><d:prop><d:getcontentlength>2048</d:getcontentlength><d:getlastmodified>Tue, 02 Jan 2024 03:04:05 GMT</d:getlastmodified></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
        <d:response><d:href>/outside.json</d:href><d:propstat><d:prop/><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
        <d:response><d:href>/dav/failed.json</d:href><d:propstat><d:prop/><d:status>HTTP/1.1 403 Forbidden</d:status></d:propstat></d:response>
        <d:response><d:href>/dav/folder.json</d:href><d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
      </d:multistatus>"""
            server.enqueue(MockResponse().setResponseCode(207).setBody(xml))
            WebDav(server.url("/dav/").toString(), "qa", "fictional-server-password", "", transport)
                .use { client ->
                    val files = client.list()
                    assertEquals(1, files.size)
                    assertEquals(2048L, files[0].size)
                    assertNotNull(files[0].modified)
                    assertEquals("PROPFIND", server.takeRequest(5, TimeUnit.SECONDS)?.method)
                    server.enqueue(
                        MockResponse()
                            .setResponseCode(302)
                            .setHeader("Location", "https://example.test/outside")
                    )
                    assertThrows(Exception::class.java) { client.download(files[0]) }
                    assertEquals("GET", server.takeRequest(5, TimeUnit.SECONDS)?.method)
                }
        } finally {
            server.shutdown()
        }
    }
}
