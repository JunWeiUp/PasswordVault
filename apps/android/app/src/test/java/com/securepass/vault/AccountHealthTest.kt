package com.securepass.vault

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class AccountHealthTest {
    /** Builds synthetic, non-repeating test strings of the given character mix. */
    private fun sample(lower: Int = 0, upper: Int = 0, digits: Int = 0, symbols: Int = 0) =
        ('a'..'z').joinToString("").take(lower) + ('A'..'Z').joinToString("").take(upper) +
            ('0'..'9').joinToString("").take(digits) + "!@#$%^&*".take(symbols)

    @Test fun strengthNeverRatesCoreWeakPasswordsAboveWeak() {
        assertEquals(0, passwordStrength(""))
        assertEquals(0, passwordStrength("abc123"))
        assertEquals(1, passwordStrength(sample(lower = 8, digits = 2)))   // 10 chars: core audit flags < 12 as weak
        assertTrue(passwordStrength("correcthorse") >= 2)
    }

    @Test fun strengthRewardsLengthAndVariety() {
        assertEquals(2, passwordStrength(sample(lower = 12)))
        assertEquals(3, passwordStrength(sample(lower = 6, upper = 4, digits = 4)))
        assertEquals(4, passwordStrength(sample(lower = 10, upper = 6, digits = 6)))
        assertEquals(4, passwordStrength(sample(lower = 6, upper = 4, digits = 4, symbols = 2)))
        // Repetition caps the score even when long.
        assertEquals(2, passwordStrength("aaaaaaaaaaaaaaaaaaaaaaaa"))
    }

    @Test fun labelsCoverEveryScore() {
        val t: (String, String) -> String = { zh, _ -> zh }
        assertEquals(listOf("很弱", "弱", "一般", "强", "很强"), (0..4).map { strengthLabel(it, t) })
        assertEquals("很强", strengthLabel(9, t))
    }

    @Test fun healthIssueFollowsAuditPriority() {
        assertNull(healthIssue(null))
        assertNull(healthIssue(JSONObject().put("id", "a")))
        assertEquals(AccountHealthIssue.WEAK, healthIssue(JSONObject().put("weak", true).put("reused", true)))
        assertEquals(AccountHealthIssue.REUSED, healthIssue(JSONObject().put("reused", true).put("expired", true)))
        assertEquals(AccountHealthIssue.EXPIRED, healthIssue(JSONObject().put("expired", true)))
    }

    @Test fun saveFailureDetailsContainOnlyTheErrorKind() {
        val details = saveFailureDetails("Storage", "password", true, 35, "1.2.3")
        assertTrue(details.contains("error: Storage"))
        assertTrue(details.contains("operation: update"))
        assertTrue(details.contains("item type: password"))
        // Anything that is not a plain identifier is replaced, so no value can leak through.
        val hostile = saveFailureDetails("SYNTHETIC-PASSWORD-CANARY hunter2", "pass word", false, 35, "x y")
        assertFalse(hostile.contains("CANARY"))
        assertFalse(hostile.contains("hunter2"))
        assertTrue(hostile.contains("error: Unknown"))
        assertTrue(hostile.contains("item type: unknown"))
        assertTrue(hostile.contains("operation: create"))
        assertTrue(saveFailureDetails(null, "totp", false, 35, "1").contains("error: Unknown"))
    }
}
