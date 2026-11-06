package com.passwordvault.testlogin

import android.app.Activity
import android.os.Bundle
import android.os.CancellationSignal
import android.widget.Button
import android.widget.LinearLayout
import android.widget.TextView
import androidx.annotation.RequiresApi
import androidx.credentials.*
import androidx.credentials.exceptions.*
import org.json.JSONObject
import org.json.JSONArray
import java.math.BigInteger
import java.security.*
import java.security.spec.ECGenParameterSpec
import java.security.spec.ECParameterSpec
import java.security.spec.ECPoint
import java.security.spec.ECPublicKeySpec
import java.util.Base64

/** Real Credential Manager calls against a synthetic RP with locally served TLS asset links. */
@RequiresApi(34)
class PasskeyFixtureActivity : Activity() {
    private lateinit var status:TextView
    private val rp="127.0.0.1.nip.io"
    private val prefs get()=getSharedPreferences("passkey-public-fixture",MODE_PRIVATE)
    private fun encode(bytes:ByteArray)=Base64.getUrlEncoder().withoutPadding().encodeToString(bytes)
    private fun decode(value:String)=Base64.getUrlDecoder().decode(value)
    private fun challenge()=ByteArray(32).also{SecureRandom().nextBytes(it)}
    override fun onCreate(state:Bundle?){
        super.onCreate(state)
        val root=LinearLayout(this).apply{orientation=LinearLayout.VERTICAL;setPadding(48,160,48,48)}
        root.addView(TextView(this).apply{text="Synthetic Passkey QA — local RP, no server account"})
        status=TextView(this).apply{text="Ready"}
        root.addView(Button(this).apply{text="Create synthetic passkey";isAllCaps=false;setOnClickListener{create()}})
        root.addView(Button(this).apply{text="Use synthetic passkey";isAllCaps=false;setOnClickListener{get()}})
        root.addView(status);setContentView(root)
    }
    private fun create(){
        val nonce=challenge();status.text="Creating…"
        val options=JSONObject().put("challenge",encode(nonce)).put("rp",JSONObject().put("id",rp).put("name","PasswordVault local QA"))
            .put("user",JSONObject().put("id",encode("native-synthetic-user".toByteArray())).put("name","native-qa@example.test").put("displayName","Native QA"))
            .put("pubKeyCredParams",JSONArray().put(JSONObject().put("type","public-key").put("alg",-7)))
            .put("authenticatorSelection",JSONObject().put("residentKey","required").put("userVerification","required")).put("attestation","none").put("timeout",300000)
        CredentialManager.create(this).createCredentialAsync(this,CreatePublicKeyCredentialRequest(options.toString()),CancellationSignal(),mainExecutor,object:CredentialManagerCallback<CreateCredentialResponse,CreateCredentialException>{
            override fun onError(e:CreateCredentialException){status.text="Registration FAIL: ${e.type}"}
            override fun onResult(result:CreateCredentialResponse){try{
                val json=JSONObject((result as CreatePublicKeyCredentialResponse).registrationResponseJson);val response=json.getJSONObject("response")
                client(decode(response.getString("clientDataJSON")),nonce,"webauthn.create")
                val attestation=Cbor(decode(response.getString("attestationObject"))).read() as Map<*,*>
                val auth=attestation["authData"] as ByteArray;checkAuth(auth)
                val length=((auth[53].toInt() and 255) shl 8)+(auth[54].toInt() and 255)
                val key=Cbor(auth.copyOfRange(55+length,auth.size)).read() as Map<*,*>
                prefs.edit().putString("id",json.getString("id")).putString("x",encode(key[-2] as ByteArray)).putString("y",encode(key[-3] as ByteArray)).apply()
                status.text="Registration PASS: framework response, RP and UV verified"
            }catch(e:Exception){status.text="Registration FAIL: ${e.message}"}}
        })
    }
    private fun get(){
        val id=prefs.getString("id",null);if(id==null){status.text="Register first";return};val nonce=challenge();status.text="Signing…"
        val options=JSONObject().put("challenge",encode(nonce)).put("rpId",rp).put("userVerification","required").put("timeout",300000)
            .put("allowCredentials",JSONArray().put(JSONObject().put("type","public-key").put("id",id)))
        CredentialManager.create(this).getCredentialAsync(this,GetCredentialRequest(listOf(GetPublicKeyCredentialOption(options.toString()))),CancellationSignal(),mainExecutor,object:CredentialManagerCallback<GetCredentialResponse,GetCredentialException>{
            override fun onError(e:GetCredentialException){status.text="Assertion FAIL: ${e.type}"}
            override fun onResult(result:GetCredentialResponse){try{
                val response=JSONObject((result.credential as PublicKeyCredential).authenticationResponseJson).getJSONObject("response")
                val data=decode(response.getString("clientDataJSON"));client(data,nonce,"webauthn.get")
                val auth=decode(response.getString("authenticatorData"));checkAuth(auth)
                val parameters=AlgorithmParameters.getInstance("EC").apply{init(ECGenParameterSpec("secp256r1"))}.getParameterSpec(ECParameterSpec::class.java)
                val point=ECPoint(BigInteger(1,decode(prefs.getString("x","")!!)),BigInteger(1,decode(prefs.getString("y","")!!)))
                val key=KeyFactory.getInstance("EC").generatePublic(ECPublicKeySpec(point,parameters))
                val verifier=Signature.getInstance("SHA256withECDSA");verifier.initVerify(key);verifier.update(auth);verifier.update(MessageDigest.getInstance("SHA-256").digest(data))
                check(verifier.verify(decode(response.getString("signature"))))
                status.text="Assertion PASS: signature, challenge, RP and UV verified"
            }catch(e:Exception){status.text="Assertion FAIL: ${e.message}"}}
        })
    }
    private fun checkAuth(auth:ByteArray){check(auth.size>=37);check(auth.copyOfRange(0,32).contentEquals(MessageDigest.getInstance("SHA-256").digest(rp.toByteArray())));check(auth[32].toInt() and 5 == 5)}
    private fun client(data:ByteArray,nonce:ByteArray,type:String){
        val json=JSONObject(String(data));check(json.getString("type")==type);check(json.getString("challenge")==encode(nonce))
        val signature=packageManager.getPackageInfo(packageName,android.content.pm.PackageManager.GET_SIGNING_CERTIFICATES).signingInfo!!.apkContentsSigners.first().toByteArray()
        check(json.getString("origin")=="android:apk-key-hash:"+encode(MessageDigest.getInstance("SHA-256").digest(signature)))
    }
    private class Cbor(private val data:ByteArray){var offset=0
        fun read():Any{val head=data[offset++].toInt() and 255;val kind=head shr 5;var n=head and 31;if(n==24)n=data[offset++].toInt() and 255 else if(n==25)n=((data[offset++].toInt() and 255) shl 8)+(data[offset++].toInt() and 255)
            return when(kind){0->n;1->-1-n;2->data.copyOfRange(offset,offset+n).also{offset+=n};3->String(data.copyOfRange(offset,offset+n)).also{offset+=n};5->mutableMapOf<Any,Any>().apply{repeat(n){put(read(),read())}};else->error("Unsupported CBOR")}}
    }
}
