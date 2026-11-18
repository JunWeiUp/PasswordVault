package com.securepass.vault

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class GeneratorOptionsTest {
    @Test
    fun characterRequestKeepsTheOriginalShape() {
        val request = GeneratorOptions(12, true, false, true, false).request()
        assertFalse(request.has("mode"))
        assertEquals(12, request.getInt("length"))
        assertTrue(request.getBoolean("upper"))
        assertFalse(request.getBoolean("lower"))
        assertTrue(request.getBoolean("digits"))
        assertFalse(request.getBoolean("symbols"))
        assertFalse(GeneratorOptions(4, false, false, false, false).enabled)
    }

    @Test
    fun passphraseRequestCarriesWordOptions() {
        val options = GeneratorOptions(passphrase = true, words = 7, separator = " ", capitalize = true, number = true)
        val request = options.request()
        assertEquals("passphrase", request.getString("mode"))
        assertEquals(7, request.getInt("words"))
        assertEquals(" ", request.getString("separator"))
        assertTrue(request.getBoolean("capitalize"))
        assertTrue(request.getBoolean("number"))
        assertFalse(request.has("length"))
        assertTrue(options.enabled)
        // Character classes do not apply to word mode.
        assertTrue(GeneratorOptions(4, false, false, false, false, passphrase = true).enabled)
    }

    @Test
    fun passphraseDefaultsAndLimitsMatchTheCore() {
        val defaults = GeneratorOptions(passphrase = true).request()
        assertEquals(5, defaults.getInt("words"))
        assertEquals("-", defaults.getString("separator"))
        assertFalse(defaults.getBoolean("capitalize"))
        assertFalse(defaults.getBoolean("number"))
        assertEquals(3..10, GeneratorOptions.WORDS)
        assertEquals(listOf("-", ".", "_", " "), GeneratorOptions.SEPARATORS)
        assertFalse(GeneratorOptions(passphrase = true, words = 2).enabled)
        assertFalse(GeneratorOptions(passphrase = true, words = 11).enabled)
        assertFalse(GeneratorOptions(passphrase = true, separator = "/").enabled)
    }
}
