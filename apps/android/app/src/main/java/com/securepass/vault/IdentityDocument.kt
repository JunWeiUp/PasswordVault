package com.securepass.vault

import org.json.JSONArray
import org.json.JSONObject

/**
 * Identity document data shared with desktop and iOS. Document values live in `customFields`
 * (group `document`) because the core accepts only [CORE_IDENTITY_FIELDS] inside `identity`;
 * names stay in `identity.firstName` / `identity.lastName`.
 */
internal object IdentityDocument {
    const val GROUP = "document"

    data class Field(val id: String, val zh: String, val en: String, val kind: String)

    val FIELDS = listOf(
        Field("document.type", "证件类型", "Document type", "text"),
        Field("document.number", "证件号码", "Document number", "concealed"),
        Field("document.issuer", "签发机关", "Issuing authority", "text"),
        Field("document.issueDate", "签发日期", "Issue date", "date"),
        Field("document.expiryDate", "有效期至", "Valid until", "date"),
    )
    private val ids = FIELDS.map { it.id }.toSet()

    /** Identity keys accepted by the released core (`structured.rs` IDENTITY_FIELDS). */
    val CORE_IDENTITY_FIELDS = listOf("lastName", "firstName", "email", "phone", "address1", "address2", "city", "region", "postalCode", "country", "company")
    /** Card keys accepted by the released core (`structured.rs` CARD_FIELDS). */
    val CORE_CARD_FIELDS = listOf("cardholder", "number", "expiryMonth", "expiryYear", "securityCode", "brand")

    fun isDocumentField(field: JSONObject): Boolean = field.optString("id") in ids

    fun field(id: String): Field? = FIELDS.firstOrNull { it.id == id }

    fun label(id: String, t: (String, String) -> String): String = field(id)?.let { t(it.zh, it.en) } ?: id

    fun value(item: JSONObject, id: String): String {
        val fields = item.optJSONArray("customFields") ?: return ""
        for (index in 0 until fields.length()) {
            val field = fields.optJSONObject(index) ?: continue
            if (field.optString("id") == id) return field.optString("value")
        }
        return ""
    }

    /**
     * Returns a new `customFields` array with [id] set to [value]. Every other entry, and every
     * unknown key on the updated entry, is kept. A blank value never creates a new entry.
     */
    fun withValue(fields: JSONArray?, id: String, value: String): JSONArray {
        val spec = requireNotNull(field(id)) { "Unknown document field" }
        val next = JSONArray((fields ?: JSONArray()).toString())
        for (index in 0 until next.length()) {
            val existing = next.optJSONObject(index) ?: continue
            if (existing.optString("id") == id) {
                existing.put("value", value)
                if (existing.optString("group").isBlank()) existing.put("group", GROUP)
                if (existing.optString("label").isBlank()) existing.put("label", spec.zh)
                if (existing.optString("kind") !in setOf("text", "concealed", "url", "email", "date")) existing.put("kind", spec.kind)
                return next
            }
        }
        if (value.isNotEmpty()) next.put(JSONObject().put("id", id).put("group", GROUP).put("label", spec.zh).put("kind", spec.kind).put("value", value))
        return next
    }

    /** `YYYY-MM-DD` with a real calendar date; blank is allowed. */
    fun isValidDate(value: String): Boolean {
        if (value.isEmpty()) return true
        if (!Regex("\\d{4}-\\d{2}-\\d{2}").matches(value)) return false
        return runCatching { java.time.LocalDate.parse(value) }.isSuccess
    }

    /** Document date fields of [item] whose value is not a valid `YYYY-MM-DD` date. */
    fun invalidDates(item: JSONObject): List<String> =
        FIELDS.filter { it.kind == "date" && !isValidDate(value(item, it.id).trim()) }.map { it.id }

    /** Identity keys outside the core whitelist (legacy/imported); shown read-only, never written. */
    fun legacyIdentityKeys(identity: JSONObject?): List<String> =
        identity?.keys()?.asSequence()?.filter { it !in CORE_IDENTITY_FIELDS }?.sorted()?.toList().orEmpty()

    fun holderName(identity: JSONObject?, chinese: Boolean): String {
        if (identity == null) return ""
        val first = identity.optString("firstName").trim()
        val last = identity.optString("lastName").trim()
        val composed = if (chinese) last + first else listOf(first, last).filter { it.isNotEmpty() }.joinToString(" ")
        return composed.ifBlank { identity.optString("fullName").ifBlank { identity.optString("name") } }
    }
}
