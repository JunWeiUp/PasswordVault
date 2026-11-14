package com.securepass.vault

import org.junit.Assert.*
import org.junit.Test

class RelaySyncProgressTest {
    @Test fun relayDeliveryDoesNotClearPrimaryConfirmation() {
        assertEquals(RelaySyncPhase.WAITING_FOR_PRIMARY, completedSyncPhase(2, false, false))
        assertEquals(RelaySyncPhase.CHECKED, completedSyncPhase(0, false, false))
    }
    @Test fun peerCheckDoesNotInventLegacyPendingAcknowledgements() {
        assertEquals(RelaySyncPhase.CHECKED, completedSyncPhase(2, true, false))
    }
    @Test fun negotiationBlocksAClaimOfCompletion() {
        assertEquals(RelaySyncPhase.WAITING_FOR_CAPABILITY, completedSyncPhase(0, false, true))
        assertEquals(RelaySyncPhase.WAITING_FOR_CAPABILITY, completedSyncPhase(2, false, true))
    }
    @Test fun progressUsesOnlyKnownTransferUnits() {
        assertNull(RelaySyncProgress(RelaySyncPhase.SENDING).fraction)
        assertEquals(.5f, RelaySyncProgress(RelaySyncPhase.SENDING, 2, 4).fraction!!, .001f)
        assertEquals(1f, RelaySyncProgress(RelaySyncPhase.SENDING, 5, 4).fraction!!, .001f)
        assertFalse(RelaySyncProgress(RelaySyncPhase.WAITING_FOR_PRIMARY).running)
        assertFalse(RelaySyncProgress(RelaySyncPhase.FAILED).running)
    }
    @Test fun automaticDeliveryKeepsExistingDeduplicationIdentity() {
        val expected = java.security.MessageDigest.getInstance("SHA-256").digest("peerpacket".toByteArray())
            .joinToString("") { "%02x".format(it) }.take(32)
        assertEquals(expected, relayDeliveryId("peer", "packet"))
    }
    @Test fun explicitRetryIsNotSuppressedByAnOlderDeliveryReceipt() {
        val original = relayDeliveryId("peer", "packet")
        val retry = relayDeliveryId("peer", "packet", "attempt-1")
        assertNotEquals(original, retry)
        assertNotEquals(retry, relayDeliveryId("peer", "packet", "attempt-2"))
        assertEquals(retry, relayDeliveryId("peer", "packet", "attempt-1"))
    }
}
