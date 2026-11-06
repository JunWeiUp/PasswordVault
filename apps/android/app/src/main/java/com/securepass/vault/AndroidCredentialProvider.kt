package com.securepass.vault

import android.app.PendingIntent
import android.content.Intent
import android.os.CancellationSignal
import android.os.OutcomeReceiver
import androidx.annotation.RequiresApi
import androidx.credentials.exceptions.*
import androidx.credentials.provider.*
import java.util.concurrent.atomic.AtomicInteger

@RequiresApi(34)
class AndroidCredentialProvider : CredentialProviderService() {
    override fun onBeginCreateCredentialRequest(request: BeginCreateCredentialRequest, cancellationSignal: CancellationSignal, callback: OutcomeReceiver<BeginCreateCredentialResponse, CreateCredentialException>) {
        if (cancellationSignal.isCanceled) return
        if (request !is BeginCreatePublicKeyCredentialRequest) { callback.onError(CreateCredentialUnknownException("Unsupported credential")); return }
        callback.onResult(BeginCreateCredentialResponse(listOf(CreateEntry("PasswordVault", pending("create")))))
    }
    override fun onBeginGetCredentialRequest(request: BeginGetCredentialRequest, cancellationSignal: CancellationSignal, callback: OutcomeReceiver<BeginGetCredentialResponse, GetCredentialException>) {
        if (cancellationSignal.isCanceled) return
        callback.onResult(if (request.beginGetCredentialOptions.any { it is BeginGetPublicKeyCredentialOption }) BeginGetCredentialResponse(authenticationActions=listOf(AuthenticationAction("解锁 PasswordVault / Unlock",pending("discover")))) else BeginGetCredentialResponse())
    }
    override fun onClearCredentialStateRequest(request: ProviderClearCredentialStateRequest, cancellationSignal: CancellationSignal, callback: OutcomeReceiver<Void?, ClearCredentialException>) {
        if (!cancellationSignal.isCanceled) callback.onResult(null)
    }
    private fun pending(mode: String): PendingIntent = PendingIntent.getActivity(this, ids.incrementAndGet(), Intent(this, PasskeyProviderActivity::class.java).putExtra("mode",mode), PendingIntent.FLAG_MUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
    companion object { val ids=AtomicInteger(10000) }
}
