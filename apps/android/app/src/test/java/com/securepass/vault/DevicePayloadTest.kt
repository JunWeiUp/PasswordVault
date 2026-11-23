package com.securepass.vault

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class DevicePayloadTest {
    private fun stored(): JSONObject = JSONObject()
        .put("id", "dev-1").put("type", "device").put("title", "Build host").put("username", "")
        .put("note", "kept note").put("tags", JSONArray(listOf("lab"))).put("isFavorite", true)
        .put("createdAt", "2026-01-01T00:00:00Z").put("futureTopLevel", JSONObject().put("x", 1))
        .put("device", JSONObject()
            .put("version", 1).put("host", "build.example.test").put("port", 2222).put("username", "deploy")
            .put("authMethod", "key").put("password", "").put("privateKey", "SYNTHETIC-KEY")
            .put("aliases", JSONArray(listOf("builder", "ci")))
            .put("notes", "rack 3")
            .put("services", JSONArray().put(JSONObject().put("id", "s1").put("name", "VNC").put("kind", "vnc").put("remotePort", 5900).put("localPort", 5901).put("path", "").put("futureServiceField", true)))
            .put("commands", JSONArray().put(JSONObject().put("id", "c1").put("title", "deploy.sh").put("text", "echo hi").put("secret", true)))
            .put("files", JSONArray().put(JSONObject().put("attachmentId", "f1").put("name", "notes.txt").put("mime", "text/plain").put("size", 12)))
            .put("futureDeviceField", "keep me"))

    @Test fun roundTripPreservesEveryFieldThePhoneDoesNotEdit() {
        val original = stored()
        val form = DevicePayload.form(original)
        assertEquals(DeviceForm("Build host", "build.example.test", "2222", "deploy", "", "rack 3"), form)
        // Applying the unchanged form is a no-op on the payload.
        assertEquals(original.toString(), DevicePayload.apply(original, form).toString())

        val edited = DevicePayload.apply(original, form.copy(title = " Renamed ", host = "10.0.0.7", port = "22", username = "ops", password = "pw", notes = "moved"))
        val device = edited.getJSONObject("device")
        assertEquals("Renamed", edited.getString("title"))
        assertEquals("10.0.0.7", device.getString("host"))
        assertEquals(22, device.getInt("port"))
        assertEquals("ops", device.getString("username"))
        assertEquals("pw", device.getString("password"))
        assertEquals("moved", device.getString("notes"))
        // Untouched: aliases, services, commands, files, key, auth method and unknown fields.
        val before = original.getJSONObject("device")
        for (key in listOf("aliases", "services", "commands", "files", "privateKey", "authMethod", "futureDeviceField", "version"))
            assertEquals(key, before.get(key).toString(), device.get(key).toString())
        for (key in listOf("id", "type", "note", "tags", "isFavorite", "createdAt", "futureTopLevel"))
            assertEquals(key, original.get(key).toString(), edited.get(key).toString())
        // The input record itself is not mutated.
        assertEquals("Build host", original.getString("title"))
        assertEquals(2222, original.getJSONObject("device").getInt("port"))
    }

    @Test fun blankDeviceMatchesTheCoreSchema() {
        val blank = DevicePayload.blank("2026-01-01T00:00:00Z")
        val device = blank.getJSONObject("device")
        assertEquals("device", blank.getString("type"))
        assertEquals(1, device.getInt("version"))
        assertEquals(22, device.getInt("port"))
        assertEquals("password", device.getString("authMethod"))
        for (key in listOf("aliases", "services", "commands", "files")) assertEquals(0, device.getJSONArray(key).length())
        assertTrue(blank.optString("sharedVaultId").isEmpty())
        val created = DevicePayload.apply(blank, DeviceForm(title = "NAS", host = "nas.local", port = "22"))
        assertEquals("nas.local", created.getJSONObject("device").getString("host"))
    }

    @Test fun invalidHostsAreRejected() {
        for (host in listOf("bad host", "-oProxyCommand=x", "a.example; rm -rf /", "user@host", "host/path", "\$(id)", ".hidden", "a".repeat(1025)))
            assertEquals(host, DeviceFormError.HOST, DevicePayload.validate(DeviceForm(title = "T", host = host)))
        for (host in listOf("", "server.example.test", "10.0.0.5", "[fe80::1%eth0]", "fe80::1", "主机.example", "my_host"))
            assertNull(host, DevicePayload.validate(DeviceForm(title = "T", host = host)))
    }

    @Test fun invalidPortsAndTitlesAreRejected() {
        for (port in listOf("", "0", "65536", "70000", "-1", "22a", "123456"))
            assertEquals(port, DeviceFormError.PORT, DevicePayload.validate(DeviceForm(title = "T", port = port)))
        assertEquals(65535, DevicePayload.parsePort("65535"))
        assertEquals(1, DevicePayload.parsePort("1"))
        assertEquals(DeviceFormError.TITLE, DevicePayload.validate(DeviceForm(title = "  ")))
        assertEquals(DeviceFormError.TOO_LONG, DevicePayload.validate(DeviceForm(title = "T", username = "u".repeat(1025))))
        // apply() refuses invalid input instead of writing it.
        assertThrows(IllegalArgumentException::class.java) { DevicePayload.apply(stored(), DeviceForm(title = "T", port = "0")) }
    }

    @Test fun unsupportedDeviceVersionsAreNeverRewritten() {
        val future = stored().apply { getJSONObject("device").put("version", 2) }
        assertFalse(DevicePayload.editable(future, true))
        assertThrows(IllegalArgumentException::class.java) { DevicePayload.apply(future, DevicePayload.form(future)) }
    }

    @Test fun readOnlySharedAndDeletedDevicesAreNotEditable() {
        assertTrue(DevicePayload.editable(stored(), canEdit = true))
        assertFalse("Read-only library", DevicePayload.editable(stored(), canEdit = false))
        assertFalse("Shared vault", DevicePayload.editable(stored().put("sharedVaultId", "shared-1"), canEdit = true))
        assertFalse("In Trash", DevicePayload.editable(stored().put("isDeleted", true), canEdit = true))
        assertFalse("Not a device", DevicePayload.editable(stored().put("type", "password"), canEdit = true))
        assertFalse("Missing device object", DevicePayload.editable(stored().apply { remove("device") }, canEdit = true))
    }

    @Test fun creationNeedsFormatSevenAndAWritablePersonalLibrary() {
        assertTrue(DevicePayload.canCreate(JSONObject().put("devicesEnabled", true), true))
        assertFalse("Format below 7", DevicePayload.canCreate(JSONObject(), true))
        assertFalse("Read-only", DevicePayload.canCreate(JSONObject().put("devicesEnabled", true), false))
    }
}
