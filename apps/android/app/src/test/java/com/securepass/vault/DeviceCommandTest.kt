package com.securepass.vault

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Test

class DeviceCommandTest {
    private fun device(vararg pairs: Pair<String, Any>) = JSONObject().put("version", 1).apply { pairs.forEach { (k, v) -> put(k, v) } }

    @Test fun buildsSshCommandWithUserHostAndNonDefaultPort() {
        assertEquals("ssh -p 2222 deploy@server.example.test", DeviceCommand.ssh(device("host" to "server.example.test", "port" to 2222, "username" to "deploy")))
        assertEquals("ssh deploy@10.0.0.5", DeviceCommand.ssh(device("host" to "10.0.0.5", "port" to 22, "username" to "deploy")))
        assertEquals("ssh host.example.test", DeviceCommand.ssh(device("host" to "host.example.test")))
    }

    @Test fun neverIncludesSecrets() {
        val command = DeviceCommand.ssh(device(
            "host" to "server.example.test", "username" to "deploy",
            "password" to "SYNTHETIC-PASSWORD-CANARY", "privateKey" to "SYNTHETIC-KEY-CANARY", "notes" to "NOTE-CANARY",
        ))!!
        assertFalse(command.contains("CANARY"))
    }

    @Test fun rejectsUnusableOrOptionLikeValues() {
        assertNull(DeviceCommand.ssh(null))
        assertNull(DeviceCommand.ssh(JSONObject().put("version", 2).put("host", "a.example")))
        assertNull(DeviceCommand.ssh(device("host" to "")))
        assertNull(DeviceCommand.ssh(device("host" to "-oProxyCommand=evil")))
        assertNull(DeviceCommand.ssh(device("host" to "a.example; rm -rf /")))
        // An unsafe username is dropped rather than passed to the shell.
        assertEquals("ssh a.example", DeviceCommand.ssh(device("host" to "a.example", "username" to "-oProxyCommand=x")))
        assertEquals("ssh a.example", DeviceCommand.ssh(device("host" to "a.example", "username" to "bad user")))
        assertEquals("ssh a.example", DeviceCommand.ssh(device("host" to "a.example", "port" to 70000)))
    }
}
