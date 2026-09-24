package com.securepass.vault

/** Tokens bind decoding and asynchronous validation to the still-visible scanner session. */
internal class QrScanSession {
    private var revision = 0L
    private var active = false
    private var closed = false
    private var delivered = false
    private var pending = false

    @Synchronized
    fun resume() {
        if (!closed && !delivered) active = true
    }

    @Synchronized
    fun pause() {
        active = false
        pending = false
        revision++
    }

    @Synchronized
    fun close() {
        closed = true
        pause()
    }

    @Synchronized fun canScan(): Boolean = active && !closed && !delivered && !pending

    @Synchronized
    fun begin(): Long? {
        if (!canScan()) return null
        pending = true
        return revision
    }

    @Synchronized
    fun owns(token: Long): Boolean = active && !closed && !delivered && pending && revision == token

    @Synchronized
    fun accept(token: Long): Boolean {
        if (!owns(token)) return false
        delivered = true
        pending = false
        return true
    }

    @Synchronized
    fun reject(token: Long) {
        if (owns(token)) pending = false
    }
}
