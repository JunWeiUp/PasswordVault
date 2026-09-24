package com.securepass.vault

import org.json.JSONArray

/**
 * CSV imports supported by the legacy Android UI; parses quoted multiline fields without logging.
 */
internal fun parseMigrationCsv(content: String, provider: String): String {
    require(provider in listOf("lastpass", "bitwarden", "1password", "chrome"))
    val rows = mutableListOf<List<String>>()
    var row = mutableListOf<String>()
    val cell = StringBuilder()
    var quoted = false
    var closed = false
    var index = 0
    val text = content.removePrefix("\uFEFF")
    fun cellDone() {
        row.add(cell.toString())
        cell.setLength(0)
        closed = false
    }
    fun rowDone() {
        cellDone()
        if (row.any { it.isNotBlank() }) rows.add(row)
        row = mutableListOf()
    }
    while (index < text.length) {
        val char = text[index]
        when {
            quoted && char == '"' -> {
                if (index + 1 < text.length && text[index + 1] == '"') {
                    cell.append('"')
                    index++
                } else {
                    quoted = false
                    closed = true
                }
            }
            quoted -> cell.append(char)
            char == ',' -> cellDone()
            char == '\n' || char == '\r' -> {
                rowDone()
                if (char == '\r' && index + 1 < text.length && text[index + 1] == '\n') index++
            }
            char == '"' && cell.isEmpty() && !closed -> quoted = true
            else -> {
                require(!closed || char.isWhitespace())
                if (!closed) cell.append(char)
            }
        }
        index++
    }
    require(!quoted)
    if (cell.isNotEmpty() || row.isNotEmpty() || closed) rowDone()
    require(rows.isNotEmpty())
    val first = rows.first().map { it.trim().lowercase() }
    val headerless = provider == "lastpass" && "url" !in first
    val headers =
        if (headerless) listOf("url", "username", "password", "extra", "name", "grouping", "fav")
        else first
    require(
        headers.any {
            it in
                listOf(
                    "name",
                    "title",
                    "password",
                    "login_password",
                    "username",
                    "login_username",
                    "url",
                    "origin",
                    "login_uri",
                )
        }
    )
    val result = JSONArray()
    for (values in if (headerless) rows else rows.drop(1)) {
        require(values.size <= headers.size)
        fun get(vararg keys: String): String =
            keys
                .firstNotNullOfOrNull { key ->
                    headers
                        .indexOf(key)
                        .takeIf { it >= 0 }
                        ?.let { values.getOrElse(it) { "" } }
                        ?.takeIf { it.isNotEmpty() }
                }
                .orEmpty()
        if (
            provider == "bitwarden" &&
                get("type").isNotEmpty() &&
                !get("type").equals("login", true)
        )
            continue
        val name = if (provider == "1password") get("title", "name") else get("name", "title")
        val username = get("login_username", "username", "login", "user")
        val password = get("login_password", "password")
        val url = get("login_uri", "uri", "url", "website", "website url", "origin")
        if (listOf(name, username, password, url).all { it.isBlank() }) continue
        val defaultCategory =
            when (provider) {
                "lastpass" -> "LastPass"
                "bitwarden" -> "Bitwarden"
                "1password" -> "1Password"
                else -> "Chrome"
            }
        val item =
            VaultRepository.blank("password")
                .put("title", name.ifEmpty { url.ifEmpty { "$defaultCategory 导入" } })
                .put("username", username)
                .put("password", password)
                .put("url", url)
                .put("note", get("notes", "note", "extra"))
                .put(
                    "category",
                    get("category", "folder", "group", "grouping", "vault").ifEmpty {
                        defaultCategory
                    },
                )
        if (provider == "lastpass")
            item.put("isFavorite", get("fav", "favorite") in listOf("1", "true", "TRUE"))
        result.put(item)
    }
    require(result.length() > 0)
    return result.toString()
}
