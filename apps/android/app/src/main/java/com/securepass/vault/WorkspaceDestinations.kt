package com.securepass.vault

import org.json.JSONObject

/** UI destinations never change persisted entry types or legacy identifiers. */
internal fun workspaceDestination(type: String): String = when (type) {
    "crypto", "creditCard", "identity" -> "wallets"
    else -> type
}

internal fun matchesWorkspaceDestination(item: JSONObject, destination: String): Boolean {
    if (destination == "trash") return item.optBoolean("isDeleted")
    if (item.optBoolean("isDeleted")) return false
    return when (destination) {
        "all" -> true
        "favorites" -> item.optBoolean("isFavorite")
        "wallets" -> item.optString("type") in setOf("crypto", "creditCard", "identity")
        else -> item.optString("type") == destination
    }
}
