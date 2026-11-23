package com.securepass.vault

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class AppPreferencesTest {
    @Test fun clipboardDurationDefaultsToThirtySecondsForUnknownValues() {
        assertEquals(listOf(15, 30, 60, 120, 0), AppPreferences.CLIPBOARD_CHOICES)
        AppPreferences.CLIPBOARD_CHOICES.forEach { assertEquals(it, AppPreferences.normalizeClipboardSeconds(it)) }
        assertEquals(30, AppPreferences.normalizeClipboardSeconds(-1))
        assertEquals(30, AppPreferences.normalizeClipboardSeconds(45))
        assertEquals(30, AppPreferences.DEFAULT_CLIPBOARD_SECONDS)
    }

    @Test fun copiedNoticeMatchesTheDuration() {
        assertTrue(AppPreferences.copiedNotice(15).contains("15 秒"))
        assertTrue(AppPreferences.copiedNotice(60).contains("1 分钟"))
        assertTrue(AppPreferences.copiedNotice(120).contains("2 minutes"))
        assertTrue(AppPreferences.copiedNotice(0).contains("锁定时清除"))
    }

    @Test fun startPageResolvesToABottomDestination() {
        assertEquals("secureNote", AppPreferences.resolveStartPage(null, null))
        assertEquals("password", AppPreferences.resolveStartPage("password", "totp"))
        assertEquals("totp", AppPreferences.resolveStartPage("last", "totp"))
        assertEquals("secureNote", AppPreferences.resolveStartPage("last", null))
        // Unknown or non-destination values (e.g. settings, trash) fall back to Notes.
        assertEquals("secureNote", AppPreferences.resolveStartPage("last", "settings"))
        assertEquals("secureNote", AppPreferences.resolveStartPage("trash", "password"))
        assertEquals("secureNote", AppPreferences.resolveStartPage("last", "last"))
    }

    @Test fun offlineOnlyWhenAConfiguredRelayFailed() {
        val failed = RelaySyncProgress(RelaySyncPhase.FAILED)
        assertFalse("No group configured", relayOffline(RelayUi(sync = failed)))
        assertTrue(relayOffline(RelayUi(legacy = true, sync = failed)))
        assertTrue(relayOffline(RelayUi(managed = true, sync = failed)))
        assertTrue("Retry after a failure stays offline", relayOffline(RelayUi(mesh = true, error = "x", sync = RelaySyncProgress(RelaySyncPhase.CONNECTING))))
        assertFalse("First connection attempt is not offline", relayOffline(RelayUi(managed = true, sync = RelaySyncProgress(RelaySyncPhase.CONNECTING))))
        assertFalse(relayOffline(RelayUi(managed = true, sync = RelaySyncProgress(RelaySyncPhase.CHECKED))))
        assertFalse("Credential problems have their own message", relayOffline(RelayUi(managed = true, credentialsBlocked = true, sync = failed)))
    }
}
