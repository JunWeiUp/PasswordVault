package com.securepass.vault

import org.junit.Assert.*
import org.junit.Test

class RelaySyncProgressTest {
    @Test fun progressUsesOnlyKnownTransferUnits() {
        assertNull(RelaySyncProgress(RelaySyncPhase.SENDING).fraction)
        assertEquals(.5f, RelaySyncProgress(RelaySyncPhase.SENDING, 2, 4).fraction!!, .001f)
        assertEquals(1f, RelaySyncProgress(RelaySyncPhase.SENDING, 5, 4).fraction!!, .001f)
        assertFalse(RelaySyncProgress(RelaySyncPhase.WAITING_FOR_CAPABILITY).running)
        assertFalse(RelaySyncProgress(RelaySyncPhase.FAILED).running)
    }
}
