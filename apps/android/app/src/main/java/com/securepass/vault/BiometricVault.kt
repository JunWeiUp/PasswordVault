package com.securepass.vault

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import androidx.biometric.BiometricManager
import androidx.biometric.BiometricPrompt
import androidx.core.content.ContextCompat
import androidx.fragment.app.FragmentActivity
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

class BiometricVault(private val activity: FragmentActivity) {
    private val prefs = activity.getSharedPreferences("biometric-key", Context.MODE_PRIVATE)
    private val aliasBase = activity.packageName + ".root.biometric"
    private val alias
        get() = prefs.getString("alias", aliasBase) ?: aliasBase

    val enabled
        get() = prefs.contains("ciphertext")

    val available
        get() =
            BiometricManager.from(activity)
                .canAuthenticate(BiometricManager.Authenticators.BIOMETRIC_STRONG) ==
                BiometricManager.BIOMETRIC_SUCCESS

    private fun key(name: String = alias): SecretKey =
        KeyStore.getInstance("AndroidKeyStore").apply { load(null) }.getKey(name, null) as SecretKey

    fun observeEnabled(changed: () -> Unit): () -> Unit {
        val listener =
            android.content.SharedPreferences.OnSharedPreferenceChangeListener { _, _ -> changed() }
        prefs.registerOnSharedPreferenceChangeListener(listener)
        return { prefs.unregisterOnSharedPreferenceChangeListener(listener) }
    }

    fun disable() {
        val current = alias
        // remove() notifies listeners on API 24–29 too; clear() does not.
        prefs.edit().remove("ciphertext").remove("iv").remove("alias").commit()
        erase(current)
    }

    private fun erase(name: String) {
        runCatching {
            KeyStore.getInstance("AndroidKeyStore").apply { load(null) }.deleteEntry(name)
        }
    }

    fun enroll(root: ByteArray, complete: (Boolean) -> Unit) {
        val previous = alias
        val priorPreferences = prefs.all
        val pending = aliasBase + "." + java.util.UUID.randomUUID()
        try {
            val generator =
                KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
            generator.init(
                KeyGenParameterSpec.Builder(
                        pending,
                        KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
                    )
                    .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                    .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                    .setUserAuthenticationRequired(true)
                    .setInvalidatedByBiometricEnrollment(true)
                    .build()
            )
            generator.generateKey()
            val cipher =
                Cipher.getInstance("AES/GCM/NoPadding").apply {
                    init(Cipher.ENCRYPT_MODE, key(pending))
                }
            prompt(
                cipher,
                { authenticated ->
                    try {
                        val sealed = authenticated.doFinal(root)
                        val ok =
                            prefs
                                .edit()
                                .putString("alias", pending)
                                .putString(
                                    "ciphertext",
                                    Base64.encodeToString(sealed, Base64.NO_WRAP),
                                )
                                .putString(
                                    "iv",
                                    Base64.encodeToString(authenticated.iv, Base64.NO_WRAP),
                                )
                                .commit()
                        if (ok) erase(previous)
                        else {
                            val rollback = prefs.edit().clear()
                            priorPreferences.forEach { (key, value) ->
                                if (value is String) rollback.putString(key, value)
                            }
                            rollback.commit()
                            erase(pending)
                        }
                        complete(ok)
                    } finally {
                        root.fill(0)
                    }
                },
                {
                    erase(pending)
                    root.fill(0)
                    complete(false)
                },
            )
        } catch (_: Exception) {
            erase(pending)
            root.fill(0)
            complete(false)
        }
    }

    fun unlock(complete: (ByteArray?) -> Unit) {
        try {
            val iv = Base64.decode(prefs.getString("iv", ""), Base64.NO_WRAP)
            val data = Base64.decode(prefs.getString("ciphertext", ""), Base64.NO_WRAP)
            val cipher =
                Cipher.getInstance("AES/GCM/NoPadding").apply {
                    init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, iv))
                }
            prompt(cipher, { complete(it.doFinal(data)) }, { complete(null) })
        } catch (_: Exception) {
            complete(null)
        }
    }

    private fun prompt(cipher: Cipher, success: (Cipher) -> Unit, failure: () -> Unit) {
        val prompt =
            BiometricPrompt(
                activity,
                ContextCompat.getMainExecutor(activity),
                object : BiometricPrompt.AuthenticationCallback() {
                    override fun onAuthenticationSucceeded(
                        result: BiometricPrompt.AuthenticationResult
                    ) {
                        try {
                            result.cryptoObject?.cipher?.let(success) ?: failure()
                        } catch (_: Exception) {
                            failure()
                        }
                    }

                    override fun onAuthenticationError(code: Int, message: CharSequence) {
                        failure()
                    }
                },
            )
        prompt.authenticate(
            BiometricPrompt.PromptInfo.Builder()
                .setTitle("PasswordVault")
                .setSubtitle("解锁资料库 / Unlock vault")
                .setAllowedAuthenticators(BiometricManager.Authenticators.BIOMETRIC_STRONG)
                .setNegativeButtonText("取消 / Cancel")
                .build(),
            BiometricPrompt.CryptoObject(cipher),
        )
    }
}
