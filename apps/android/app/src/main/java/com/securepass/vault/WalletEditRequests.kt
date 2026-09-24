package com.securepass.vault

import androidx.compose.runtime.mutableIntStateOf

/** Main-thread request ownership: explicit operations invalidate pending automatic derivation. */
internal class WalletEditRequests(initial: Int = 0) {
    val revision = mutableIntStateOf(initial)

    fun begin(): Int {
        revision.intValue++
        return revision.intValue
    }

    fun owns(request: Int): Boolean = request == revision.intValue
}
