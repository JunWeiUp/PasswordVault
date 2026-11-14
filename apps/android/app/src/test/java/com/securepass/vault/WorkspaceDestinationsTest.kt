package com.securepass.vault

import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class WorkspaceDestinationsTest {
    private fun item(type: String, deleted: Boolean = false, favorite: Boolean = false) =
        JSONObject().put("type", type).put("isDeleted", deleted).put("isFavorite", favorite)

    @Test fun walletNavigationPreservesNativeTypesAndKeepsAccountsSeparate() {
        for (type in listOf("crypto", "creditCard", "identity")) {
            val record = item(type)
            assertEquals("wallets", workspaceDestination(type))
            assertTrue(matchesWorkspaceDestination(record, "wallets"))
            assertFalse(matchesWorkspaceDestination(record, "password"))
            assertEquals(type, record.getString("type"))
        }
        assertEquals("password", workspaceDestination("password"))
        assertFalse(matchesWorkspaceDestination(item("password"), "wallets"))
        assertTrue(matchesWorkspaceDestination(item("device"), "device"))
    }

    @Test fun crossTypeDestinationsNeverExposeDeletedItemsOutsideTrash() {
        for (type in listOf("password", "secureNote", "totp", "crypto", "identity", "creditCard", "device")) {
            assertTrue(matchesWorkspaceDestination(item(type), "all"))
            assertFalse(matchesWorkspaceDestination(item(type), "favorites"))
            assertTrue(matchesWorkspaceDestination(item(type, favorite = true), "favorites"))
            val deleted = item(type, deleted = true, favorite = true)
            for (destination in listOf("all", "favorites", "wallets", type)) {
                assertFalse(matchesWorkspaceDestination(deleted, destination))
            }
            assertTrue(matchesWorkspaceDestination(deleted, "trash"))
            assertFalse(matchesWorkspaceDestination(item(type), "trash"))
        }
    }
}
