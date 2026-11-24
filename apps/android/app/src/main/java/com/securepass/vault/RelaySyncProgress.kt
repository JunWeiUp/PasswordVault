package com.securepass.vault

internal enum class RelaySyncPhase {
    IDLE, REQUESTED, CONNECTING, CHECKING, SENDING, RECEIVING,
    WAITING_FOR_CAPABILITY, CHECKED, FAILED, BLOCKED,
}

/** In-memory transport progress of the symmetric sync loop. */
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

