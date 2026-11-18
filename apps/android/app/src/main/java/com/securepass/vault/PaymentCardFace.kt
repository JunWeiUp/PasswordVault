package com.securepass.vault

import org.json.JSONObject

/** What the payment-card face shows; the full number is never part of it. */
internal data class PaymentCardFace(val bank: String, val brand: String, val masked: String, val expiry: String, val holder: String)

internal fun paymentCardFace(item: JSONObject): PaymentCardFace {
    val card = item.optJSONObject("card") ?: JSONObject()
    val digits = card.optString("number").filter { it.isDigit() }
    val brand = card.optString("brand").ifBlank {
        when {
            digits.startsWith("4") -> "Visa"
            digits.startsWith("62") -> "UnionPay"
            digits.startsWith("34") || digits.startsWith("37") -> "American Express"
            digits.length >= 2 && digits.take(2).toInt() in 51..55 -> "Mastercard"
            digits.length >= 4 && digits.take(4).toInt() in 2221..2720 -> "Mastercard"
            digits.startsWith("35") -> "JCB"
            else -> ""
        }
    }
    val month = card.optString("expiryMonth").trim().let { if (it.length == 1) "0$it" else it }
    val year = card.optString("expiryYear").trim().takeLast(2)
    val expiry = card.optString("expiryDate").ifBlank { listOf(month, year).filter { it.isNotEmpty() }.joinToString("/") }
    return PaymentCardFace(
        bank = card.optString("bank").ifBlank { item.optString("title") },
        brand = brand,
        masked = if (digits.isEmpty()) "" else "•••• •••• •••• " + digits.takeLast(4),
        expiry = expiry,
        holder = card.optString("cardholder"),
    )
}
