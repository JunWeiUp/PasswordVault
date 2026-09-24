package com.securepass.vault

import java.time.Instant
import org.json.JSONArray
import org.json.JSONObject

/**
 * Compare a recovered draft with persisted data, never with the draft used to reopen the editor.
 */
internal fun prepareEntrySave(draft: JSONObject, persistedEntries: List<JSONObject>): JSONObject {
    val result = JSONObject(draft.toString())
    val persisted = persistedEntries.firstOrNull { it.optString("id") == result.optString("id") }
    val changedAt = Instant.now().toString()
    fun preservePasswordHistory(next: JSONObject, previous: JSONObject?) {
        if (previous == null) {
            if (next.optString("password").isNotEmpty() && !next.has("passwordLastChanged"))
                next.put("passwordLastChanged", changedAt)
            return
        }
        if (next.optString("password") == previous.optString("password")) {
            // A retry may resume the pre-save draft after the core already committed.
            previous.optJSONArray("passwordHistory")?.let {
                next.put("passwordHistory", JSONArray(it.toString()))
            }
            if (previous.has("passwordLastChanged"))
                next.put("passwordLastChanged", previous.get("passwordLastChanged"))
            return
        }
        val history = JSONArray()
        if (previous.optString("password").isNotEmpty())
            history.put(
                JSONObject()
                    .put("password", previous.optString("password"))
                    .put("changedAt", changedAt)
            )
        previous.optJSONArray("passwordHistory")?.let { old ->
            for (i in 0 until old.length()) history.put(old.get(i))
        }
        next.put("passwordHistory", history).put("passwordLastChanged", changedAt)
    }
    preservePasswordHistory(result, persisted)
    result.optJSONArray("accounts")?.objects()?.forEach { account ->
        preservePasswordHistory(
            account,
            persisted?.optJSONArray("accounts")?.objects()?.firstOrNull {
                it.optString("id") == account.optString("id")
            },
        )
    }
    return result
}
