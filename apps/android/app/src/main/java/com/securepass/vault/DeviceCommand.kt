package com.securepass.vault

import org.json.JSONObject

/**
 * The SSH command for a device entry, for copying or handing to a terminal app through the
 * system share sheet. It carries only user, host and port — never a password, private key or
 * any other secret — and the phone never runs it.
 */
internal object DeviceCommand {
    private val safeHost = Regex("^[A-Za-z0-9._:\\[\\]-]{1,253}$")
    private val safeUser = Regex("^[A-Za-z0-9._@-]{1,64}$")

    /** `ssh [-p PORT] [USER@]HOST`, or null when the entry has no usable host. */
    fun ssh(device: JSONObject?): String? {
        if (device == null || device.optInt("version") != 1) return null
        val host = device.optString("host").trim()
        if (!safeHost.matches(host) || host.startsWith("-")) return null
        val user = device.optString("username").trim()
        val target = if (user.isNotEmpty() && safeUser.matches(user) && !user.startsWith("-")) "$user@$host" else host
        val port = device.optInt("port", 22)
        return if (port in 1..65535 && port != 22) "ssh -p $port $target" else "ssh $target"
    }
}
