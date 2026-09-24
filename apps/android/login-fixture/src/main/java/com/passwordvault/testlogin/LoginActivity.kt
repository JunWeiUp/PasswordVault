package com.passwordvault.testlogin

import android.app.Activity
import android.os.Bundle
import android.view.View
import android.view.autofill.AutofillManager
import android.widget.*

class LoginActivity : Activity() {
    override fun onCreate(state: Bundle?) {
        super.onCreate(state)
        val root =
            LinearLayout(this).apply {
                orientation = LinearLayout.VERTICAL
                setPadding(48, 180, 48, 48)
            }
        val username =
            EditText(this).apply {
                id = 1001
                hint = "QA username"
                setAutofillHints(View.AUTOFILL_HINT_USERNAME)
                importantForAutofill = View.IMPORTANT_FOR_AUTOFILL_YES
            }
        val password =
            EditText(this).apply {
                id = 1002
                hint = "QA password"
                inputType = 129
                setAutofillHints(View.AUTOFILL_HINT_PASSWORD)
                importantForAutofill = View.IMPORTANT_FOR_AUTOFILL_YES
            }
        root.addView(TextView(this).apply { text = "Synthetic local login — no network requests" })
        root.addView(username)
        root.addView(password)
        root.addView(
            Button(this).apply {
                setAllCaps(false)
                text = "Request Autofill"
                setOnClickListener {
                    password.requestFocus()
                    getSystemService(AutofillManager::class.java).requestAutofill(password)
                }
            }
        )
        root.addView(
            Button(this).apply {
                setAllCaps(false)
                text = "Submit QA login"
                setOnClickListener {
                    getSystemService(AutofillManager::class.java).commit()
                    root.addView(
                        TextView(this@LoginActivity).apply {
                            text = "Submitted only by explicit tap"
                        }
                    )
                }
            }
        )
        setContentView(root)
    }
}
