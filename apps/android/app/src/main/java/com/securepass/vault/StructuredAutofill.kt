package com.securepass.vault

import org.json.JSONObject

/** Explicit Android/AndroidX autofill hints only; no label or DOM text guessing. */
internal fun structuredFillKey(hint: String): String? = when (hint.lowercase()) {
    "creditcardnumber" -> "card.number"
    "creditcardexpirationmonth" -> "card.expiryMonth"
    "creditcardexpirationyear" -> "card.expiryYear"
    "creditcardexpirationdate" -> "card.expiryDate"
    "personname", "name" -> "identity.fullName"
    "persongivenname" -> "identity.firstName"
    "personfamilyname" -> "identity.lastName"
    "emailaddress" -> "identity.email"
    "phone", "phonenumber" -> "identity.phone"
    "postaladdress" -> "identity.fullAddress"
    "streetaddress" -> "identity.address1"
    "addresslocality" -> "identity.city"
    "addressregion" -> "identity.region"
    "postalcode" -> "identity.postalCode"
    "addresscountry" -> "identity.country"
    else -> null
}

internal fun structuredFillValues(item: JSONObject, requested: Set<String>): Map<String, String> {
    val group = when (item.optString("type")) { "creditCard" -> "card"; "identity" -> "identity"; else -> return emptyMap() }
    val fields = item.optJSONObject(group) ?: return emptyMap()
    val allowed = if (group == "card") setOf("number", "cardholder", "expiryMonth", "expiryYear", "expiryDate") else setOf("firstName", "lastName", "fullName", "email", "phone", "address1", "city", "region", "postalCode", "country", "fullAddress")
    return requested.mapNotNull { key ->
        if (!key.startsWith("$group.")) return@mapNotNull null
        val field = key.substringAfter('.'); if (field !in allowed) return@mapNotNull null
        val value = when (field) {
            "fullName" -> listOf(fields.optString("firstName"), fields.optString("lastName")).filter(String::isNotBlank).joinToString(" ")
            "fullAddress" -> listOf("address1", "address2", "city", "region", "postalCode", "country").map { fields.optString(it) }.filter(String::isNotBlank).joinToString(", ")
            "expiryDate" -> if (fields.optString("expiryMonth").isNotBlank() && fields.optString("expiryYear").isNotBlank()) fields.optString("expiryMonth") + "/" + fields.optString("expiryYear") else ""
            else -> fields.optString(field)
        }
        if (value.isBlank()) null else key to value
    }.toMap()
}
