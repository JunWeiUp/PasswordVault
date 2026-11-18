package com.securepass.vault

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Test

class PaymentCardFaceTest {
    // Synthetic digits built at runtime; not a real card number.
    private val visaFixture = "4" + "0".repeat(11) + "1234"

    @Test fun faceMasksTheNumberAndFallsBackToTitleAndInferredBrand() {
        val item = JSONObject().put("title", "Fixture Bank card").put("card", JSONObject()
            .put("number", visaFixture).put("cardholder", "FIXTURE PERSON").put("expiryMonth", "3").put("expiryYear", "2029"))
        val face = paymentCardFace(item)
        assertEquals("Fixture Bank card", face.bank)
        assertEquals("Visa", face.brand)
        assertEquals("•••• •••• •••• 1234", face.masked)
        assertEquals("03/29", face.expiry)
        assertEquals("FIXTURE PERSON", face.holder)
        assertFalse(face.toString().contains(visaFixture))
    }

    @Test fun storedBankAndBrandWinAndEmptyCardStaysEmpty() {
        val face = paymentCardFace(JSONObject().put("card", JSONObject().put("bank", "Legacy bank").put("brand", "UnionPay").put("number", "62" + "0".repeat(14))))
        assertEquals("Legacy bank", face.bank)
        assertEquals("UnionPay", face.brand)
        assertEquals("", paymentCardFace(JSONObject()).masked)
        assertEquals("Mastercard", paymentCardFace(JSONObject().put("card", JSONObject().put("number", "55" + "0".repeat(14)))).brand)
    }
}
