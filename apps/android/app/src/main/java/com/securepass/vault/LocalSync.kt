package com.securepass.vault

import java.net.InetSocketAddress
import java.net.NetworkInterface
import java.net.URI
import java.nio.ByteBuffer
import java.util.Collections
import java.util.concurrent.ConcurrentHashMap
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import org.java_websocket.WebSocket
import org.java_websocket.client.WebSocketClient
import org.java_websocket.drafts.Draft_6455
import org.java_websocket.extensions.IExtension
import org.java_websocket.handshake.ClientHandshake
import org.java_websocket.handshake.ServerHandshake
import org.java_websocket.protocols.Protocol
import org.java_websocket.server.WebSocketServer
import org.json.JSONObject

class LocalSync(private val vault: VaultRepository, context: android.content.Context) {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val nsd = context.getSystemService(android.net.nsd.NsdManager::class.java)
    private var registration: android.net.nsd.NsdManager.RegistrationListener? = null
    private var discovery: android.net.nsd.NsdManager.DiscoveryListener? = null
    private val mutablePeers = MutableStateFlow<List<String>>(emptyList())
    val peers = mutablePeers.asStateFlow()
    private var server: WebSocketServer? = null
    private val mutableEndpoint = MutableStateFlow("")
    val endpoint = mutableEndpoint.asStateFlow()

    fun start() {
        if (server != null || !vault.state.value.unlocked) return
        val connections = ConcurrentHashMap.newKeySet<WebSocket>()
        val draft =
            Draft_6455(
                emptyList<IExtension>(),
                listOf(Protocol("passwordvault-v2")),
                4 * 1024 * 1024,
            )
        val value =
            object : WebSocketServer(InetSocketAddress(0), listOf(draft)) {
                override fun onOpen(connection: WebSocket, handshake: ClientHandshake) {
                    if (!vault.state.value.unlocked || connections.size >= 8) {
                        connection.close()
                        return
                    }
                    connections.add(connection)
                    scope.launch {
                        delay(20_000)
                        if (connections.remove(connection)) connection.close()
                    }
                }

                override fun onClose(
                    connection: WebSocket,
                    code: Int,
                    reason: String,
                    remote: Boolean,
                ) {
                    connections.remove(connection)
                }

                override fun onError(connection: WebSocket?, ex: Exception) {
                    connection?.close()
                }

                override fun onStart() {
                    if (this@LocalSync.server !== this) {
                        stop(100)
                        return
                    }
                    val host =
                        Collections.list(NetworkInterface.getNetworkInterfaces())
                            .flatMap { Collections.list(it.inetAddresses) }
                            .firstOrNull {
                                it is java.net.Inet4Address &&
                                    it.isSiteLocalAddress &&
                                    !it.isLoopbackAddress
                            }
                            ?.hostAddress ?: "127.0.0.1"
                    mutableEndpoint.value = "ws://$host:$port"
                    advertise(port)
                }

                private fun handle(connection: WebSocket, bytes: ByteArray) {
                    if (
                        bytes.size > 4 * 1024 * 1024 ||
                            !connections.remove(connection) ||
                            !vault.state.value.unlocked
                    ) {
                        connection.close()
                        return
                    }
                    scope.launch {
                        try {
                            val packet = JSONObject(bytes.toString(Charsets.UTF_8))
                            val response =
                                vault
                                    .command("sync-respond", JSONObject().put("packet", packet))
                                    .toString()
                                    .toByteArray()
                            require(response.size <= 4 * 1024 * 1024)
                            connection.send(response)
                            connection.close()
                            vault.refresh()
                        } catch (_: Exception) {
                            connection.close()
                        }
                    }
                }

                override fun onMessage(connection: WebSocket, message: String) =
                    handle(connection, message.toByteArray())

                override fun onMessage(connection: WebSocket, message: ByteBuffer) {
                    val bytes = ByteArray(message.remaining())
                    message.get(bytes)
                    handle(connection, bytes)
                }
            }
        value.connectionLostTimeout = 20
        server = value
        value.start()
    }

    private fun advertise(port: Int) {
        val listener =
            object : android.net.nsd.NsdManager.RegistrationListener {
                override fun onServiceRegistered(info: android.net.nsd.NsdServiceInfo) {}

                override fun onRegistrationFailed(
                    info: android.net.nsd.NsdServiceInfo,
                    code: Int,
                ) {}

                override fun onServiceUnregistered(info: android.net.nsd.NsdServiceInfo) {}

                override fun onUnregistrationFailed(
                    info: android.net.nsd.NsdServiceInfo,
                    code: Int,
                ) {}
            }
        registration = listener
        runCatching {
            nsd.registerService(
                android.net.nsd.NsdServiceInfo().apply {
                    serviceName = "PasswordVault"
                    serviceType = "_passwordvault._tcp."
                    setPort(port)
                },
                android.net.nsd.NsdManager.PROTOCOL_DNS_SD,
                listener,
            )
        }
        val browser =
            object : android.net.nsd.NsdManager.DiscoveryListener {
                override fun onDiscoveryStarted(type: String) {}

                override fun onDiscoveryStopped(type: String) {}

                override fun onStartDiscoveryFailed(type: String, code: Int) {}

                override fun onStopDiscoveryFailed(type: String, code: Int) {}

                override fun onServiceFound(info: android.net.nsd.NsdServiceInfo) {
                    mutablePeers.value = (mutablePeers.value + info.serviceName).distinct().sorted()
                }

                override fun onServiceLost(info: android.net.nsd.NsdServiceInfo) {
                    mutablePeers.value = mutablePeers.value - info.serviceName
                }
            }
        discovery = browser
        runCatching {
            nsd.discoverServices(
                "_passwordvault._tcp.",
                android.net.nsd.NsdManager.PROTOCOL_DNS_SD,
                browser,
            )
        }
    }

    fun stop() {
        registration?.let { runCatching { nsd.unregisterService(it) } }
        registration = null
        discovery?.let { runCatching { nsd.stopServiceDiscovery(it) } }
        discovery = null
        mutablePeers.value = emptyList()
        val previous = server
        server = null
        mutableEndpoint.value = ""
        scope.launch { runCatching { previous?.stop(1000) } }
    }

    companion object {
        suspend fun exchange(endpoint: String, packet: JSONObject): JSONObject =
            withContext(Dispatchers.IO) {
                val uri = URI(endpoint)
                require(
                    uri.scheme in listOf("ws", "wss") &&
                        uri.host != null &&
                        uri.userInfo == null &&
                        uri.fragment == null
                )
                val response = CompletableDeferred<JSONObject>()
                val client =
                    object :
                        WebSocketClient(
                            uri,
                            Draft_6455(
                                emptyList<IExtension>(),
                                listOf(Protocol("passwordvault-v2")),
                                4 * 1024 * 1024,
                            ),
                            null,
                            15_000,
                        ) {
                        override fun onOpen(handshake: ServerHandshake) {
                            val bytes = packet.toString().toByteArray()
                            if (bytes.size > 4 * 1024 * 1024)
                                response.completeExceptionally(IllegalArgumentException())
                            else send(bytes)
                        }

                        override fun onMessage(message: String) {
                            try {
                                require(message.toByteArray().size <= 4 * 1024 * 1024)
                                response.complete(JSONObject(message))
                            } catch (e: Exception) {
                                response.completeExceptionally(e)
                            }
                        }

                        override fun onMessage(bytes: ByteBuffer) {
                            if (bytes.remaining() > 4 * 1024 * 1024)
                                response.completeExceptionally(IllegalArgumentException())
                            else {
                                val data = ByteArray(bytes.remaining())
                                bytes.get(data)
                                onMessage(data.toString(Charsets.UTF_8))
                            }
                        }

                        override fun onClose(code: Int, reason: String, remote: Boolean) {
                            if (!response.isCompleted)
                                response.completeExceptionally(
                                    IllegalStateException("Connection closed")
                                )
                        }

                        override fun onError(ex: Exception) {
                            response.completeExceptionally(ex)
                        }
                    }
                try {
                    client.connect()
                    withTimeout(20_000) { response.await() }
                } finally {
                    client.close()
                }
            }
    }
}
