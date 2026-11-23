package com.securepass.vault

import org.junit.Assert.assertTrue
import org.junit.Test

class RelayExitBehaviorTest {
    @Test fun exitMessagesDistinguishLeaveDisbandAndRemoteConfirmation() {
        assertTrue(PersonalRelay.exitPendingMessage(disband = false, hasRemote = true).contains("本机已退出"))
        assertTrue(PersonalRelay.exitPendingMessage(disband = true, hasRemote = true).contains("解散设备组"))
        assertTrue(PersonalRelay.exitPendingMessage(disband = false, hasRemote = false).contains("本机接入已清除"))

        assertTrue(PersonalRelay.exitResultMessage(disband = false, confirmed = true).contains("服务器已确认退出"))
        assertTrue(PersonalRelay.exitResultMessage(disband = false, confirmed = false).contains("服务器尚未确认退出"))
        assertTrue(PersonalRelay.exitResultMessage(disband = true, confirmed = true).contains("服务器已确认解散设备组"))
        assertTrue(PersonalRelay.exitResultMessage(disband = true, confirmed = false).contains("服务器解散未完成"))
    }
}
