package com.securepass.vault

import java.time.Instant
import java.util.UUID
import org.json.JSONArray
import org.json.JSONObject

/** The fields the phone edits on a format-7 device; everything else in the record is carried over untouched. */
internal data class DeviceForm(
    val title: String = "",
    val host: String = "",
    val port: String = "22",
    val username: String = "",
    val password: String = "",
    val notes: String = "",
)

internal enum class DeviceFormError { TITLE, HOST, PORT, TOO_LONG }

/**
 * Builds and checks device payloads. The native core validates every device save
 * (`validate_device`: version 1, port 1–65535, auth method, length limits, row IDs, no shared vault)
 * and refuses devices below format 7; these checks only reject bad input earlier with a clear message.
 */
internal object DevicePayload {
    private const val VERSION = 1

    fun blank(now: String = Instant.now().toString()): JSONObject =
        JSONObject()
            .put("id", UUID.randomUUID().toString())
            .put("type", "device")
            .put("title", "")
            .put("username", "")
            .put("note", "")
            .put("tags", JSONArray())
            .put("noteFormat", "plain")
            .put("isDeleted", false)
            .put("isFavorite", false)
            .put("isPinned", false)
            .put("createdAt", now)
            .put("device", JSONObject()
                .put("version", VERSION).put("host", "").put("port", 22).put("username", "")
                .put("authMethod", "password").put("password", "").put("privateKey", "")
                .put("aliases", JSONArray()).put("notes", "")
                .put("services", JSONArray()).put("commands", JSONArray()).put("files", JSONArray()))

    fun form(item: JSONObject): DeviceForm {
        val device = item.optJSONObject("device") ?: JSONObject()
        return DeviceForm(
            title = item.optString("title"),
            host = device.optString("host"),
            port = if (device.has("port")) device.opt("port").toString() else "22",
            username = device.optString("username"),
            password = device.optString("password"),
            notes = device.optString("notes"),
        )
    }

    /** Host may stay empty (document-only devices, as on desktop); otherwise a plain host name or IP. */
    fun validHost(host: String): Boolean {
        if (host.isEmpty()) return true
        if (host.length > 1024 || host.first() == '-' || host.first() == '.') return false
        return host.all { it.isLetterOrDigit() || it in ".-_:[]%" }
    }

    fun parsePort(port: String): Int? = port.trim().takeIf { it.isNotEmpty() && it.length <= 5 && it.all(Char::isDigit) }?.toInt()?.takeIf { it in 1..65535 }

    fun validate(form: DeviceForm): DeviceFormError? = when {
        form.title.isBlank() -> DeviceFormError.TITLE
        !validHost(form.host.trim()) -> DeviceFormError.HOST
        parsePort(form.port) == null -> DeviceFormError.PORT
        form.username.length > 1024 || form.password.length > 65536 || form.notes.length > 262144 -> DeviceFormError.TOO_LONG
        else -> null
    }

    /**
     * Returns a deep copy of [original] with only the edited fields replaced. Aliases, services,
     * commands, files, the private key, the auth method and any unknown (future) fields survive.
     */
    fun apply(original: JSONObject, form: DeviceForm): JSONObject {
        require(validate(form) == null) { "Invalid device form" }
        val item = JSONObject(original.toString())
        val device = item.optJSONObject("device")?.let { JSONObject(it.toString()) } ?: blank().getJSONObject("device")
        require(device.optInt("version") == VERSION) { "Unsupported device version" }
        device.put("host", form.host.trim())
            .put("port", parsePort(form.port)!!)
            .put("username", form.username)
            .put("password", form.password)
            .put("notes", form.notes)
        return item.put("title", form.title.trim()).put("device", device)
    }

    /** Only active, personal, version-1 devices in a writable library can be edited on the phone. */
    fun editable(item: JSONObject, canEdit: Boolean): Boolean =
        canEdit &&
            item.optString("type") == "device" &&
            !item.optBoolean("isDeleted") &&
            item.optString("sharedVaultId").isEmpty() &&
            item.optJSONObject("device")?.optInt("version") == VERSION

    /** New devices need a vault already upgraded to format 7; the upgrade itself stays on desktop. */
    fun canCreate(settings: JSONObject, canWriteLibrary: Boolean): Boolean =
        canWriteLibrary && settings.optBoolean("devicesEnabled") && settings.optString("activePeerLibrary").isEmpty()
}
