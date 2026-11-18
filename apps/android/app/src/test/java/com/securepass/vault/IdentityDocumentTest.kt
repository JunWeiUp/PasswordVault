package com.securepass.vault

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class IdentityDocumentTest {
    @Test fun newValuesUseTheSharedCustomFieldSchema() {
        var fields: JSONArray? = null
        fields = IdentityDocument.withValue(fields, "document.number", "FIXTURE-0001")
        fields = IdentityDocument.withValue(fields, "document.expiryDate", "2031-05-01")
        val number = fields.getJSONObject(0)
        assertEquals("document.number", number.getString("id"))
        assertEquals("document", number.getString("group"))
        assertEquals("证件号码", number.getString("label"))
        assertEquals("concealed", number.getString("kind"))
        assertEquals("FIXTURE-0001", number.getString("value"))
        val expiry = fields.getJSONObject(1)
        assertEquals("date", expiry.getString("kind"))
        assertEquals("有效期至", expiry.getString("label"))
        assertEquals(setOf("id", "group", "label", "kind", "value"), number.keys().asSequence().toSet())
    }

    @Test fun blankValueDoesNotCreateAnEntry() {
        assertEquals(0, IdentityDocument.withValue(JSONArray(), "document.issuer", "").length())
    }

    @Test fun updatesPreserveOtherFieldsAndUnknownKeys() {
        val original = JSONArray()
            .put(JSONObject().put("id", "user-1").put("label", "户籍地址").put("group", "地址").put("kind", "text").put("value", "Fixture road"))
            .put(JSONObject().put("id", "document.type").put("group", "document").put("label", "证件类型").put("kind", "text").put("value", "护照").put("futureKey", "kept"))
        val next = IdentityDocument.withValue(original, "document.type", "居民身份证")
        assertEquals(2, next.length())
        assertEquals("Fixture road", next.getJSONObject(0).getString("value"))
        assertEquals("户籍地址", next.getJSONObject(0).getString("label"))
        assertEquals("居民身份证", next.getJSONObject(1).getString("value"))
        assertEquals("kept", next.getJSONObject(1).getString("futureKey"))
        // The input array is not mutated.
        assertEquals("护照", original.getJSONObject(1).getString("value"))
    }

    @Test fun readsValuesAndValidatesDates() {
        val item = JSONObject().put("type", "identity").put("customFields", IdentityDocument.withValue(null, "document.issueDate", "2024-02-30"))
        assertEquals("2024-02-30", IdentityDocument.value(item, "document.issueDate"))
        assertEquals(listOf("document.issueDate"), IdentityDocument.invalidDates(item))
        assertTrue(IdentityDocument.isValidDate(""))
        assertTrue(IdentityDocument.isValidDate("2024-02-29"))
        assertFalse(IdentityDocument.isValidDate("2024/02/01"))
        assertFalse(IdentityDocument.isValidDate("24-02-01"))
    }

    @Test fun legacyIdentityKeysAreReportedButNeverCoreKeys() {
        val identity = JSONObject().put("firstName", "Fixture").put("lastName", "Person").put("documentNumber", "OLD-1").put("fullName", "Fixture Person")
        assertEquals(listOf("documentNumber", "fullName"), IdentityDocument.legacyIdentityKeys(identity))
        assertEquals("PersonFixture", IdentityDocument.holderName(identity, chinese = true))
        assertEquals("Fixture Person", IdentityDocument.holderName(identity, chinese = false))
        assertEquals("Legacy", IdentityDocument.holderName(JSONObject().put("fullName", "Legacy"), chinese = true))
    }
}
