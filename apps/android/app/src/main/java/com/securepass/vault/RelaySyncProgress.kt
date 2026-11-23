package com.securepass.vault

internal enum class RelaySyncPhase {
    IDLE, REQUESTED, CONNECTING, CHECKING, SENDING, RECEIVING,
    WAITING_FOR_PRIMARY, WAITING_FOR_CAPABILITY, CHECKED, FAILED, PAUSED, BLOCKED,
}

/** In-memory transport progress. Delivery never stands in for the primary's acknowledgement. */
internal data class RelaySyncProgress(
    val phase: RelaySyncPhase = RelaySyncPhase.IDLE,
    val completed: Int = 0,
    val total: Int = 0,
    val lastCheckedAt: Long? = null,
    val lastSentAt: Long? = null,
) {
    val running: Boolean get() = phase in setOf(
        RelaySyncPhase.REQUESTED, RelaySyncPhase.CONNECTING, RelaySyncPhase.CHECKING,
        RelaySyncPhase.SENDING, RelaySyncPhase.RECEIVING,
    )
    val fraction: Float? get() = if (total > 0) (completed.toFloat() / total).coerceIn(0f, 1f) else null
}

internal fun relayDeliveryId(route: String, signature: String, manualRetryNonce: String = ""): String {
    // Keep automatic delivery IDs stable; an explicit retry must reach the transport again.
    val input = route + signature + if (manualRetryNonce.isEmpty()) "" else ":$manualRetryNonce"
    return java.security.MessageDigest.getInstance("SHA-256").digest(input.toByteArray(Charsets.UTF_8))
        .joinToString("") { "%02x".format(it) }.take(32)
}

