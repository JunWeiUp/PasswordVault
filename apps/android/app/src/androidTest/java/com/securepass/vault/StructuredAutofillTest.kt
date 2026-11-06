package com.securepass.vault

import androidx.test.ext.junit.runners.AndroidJUnit4
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class StructuredAutofillTest {
    @Test fun onlyStandardHintsAndExplicitGroupsAreFilled() {
        assertEquals("card.number", structuredFillKey("creditCardNumber"))
        assertEquals("identity.firstName", structuredFillKey("personGivenName"))
        assertNull(structuredFillKey("creditCardSecurityCode"))
        assertNull(structuredFillKey("password"))
        assertNull(structuredFillKey("some card number label"))
        val card = JSONObject().put("type", "creditCard").put("card", JSONObject().put("number", "synthetic-card").put("securityCode", "SECRET_NEVER_FILL").put("expiryMonth", "01").put("expiryYear", "2030")).put("importSource", JSONObject().put("secret", "NEVER_FILL"))
        val values = structuredFillValues(card, setOf("card.number", "card.securityCode", "card.expiryDate", "identity.email", "importSource.secret"))
        assertEquals(mapOf("card.number" to "synthetic-card", "card.expiryDate" to "01/2030"), values)
    }
    @Test fun identityFieldsAreComposedWithoutLeakingUnrequestedFields() {
        val identity = JSONObject().put("type", "identity").put("identity", JSONObject().put("firstName", "Fixture").put("lastName", "Person").put("email", "fixture@example.invalid").put("phone", "NOT_REQUESTED"))
        assertEquals(mapOf("identity.fullName" to "Fixture Person", "identity.email" to "fixture@example.invalid"), structuredFillValues(identity, setOf("identity.fullName", "identity.email", "card.number")))
    }
}
