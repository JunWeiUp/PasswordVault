package com.securepass.vault

import androidx.test.uiautomator.By
import androidx.test.uiautomator.UiDevice
import androidx.test.uiautomator.Until
import org.junit.Assert.assertTrue

/** Creates a vault through the current first-run flow: welcome, master password, fingerprint prompt. */
internal fun createVaultFromWelcome(device: UiDevice, password: String = "1") {
    assertTrue("Welcome screen", device.wait(Until.hasObject(By.text("新建密码库")), 10_000))
    device.findObject(By.text("新建密码库")).click()
    assertTrue("Master password step", device.wait(Until.hasObject(By.text("设置主密码")), 5_000))
    // Compose text fields take accessibility text reliably once focused.
    for (index in 0..1) {
        device.findObjects(By.clazz("android.widget.EditText"))[index].click()
        assertTrue(device.wait(Until.hasObject(By.focused(true).clazz("android.widget.EditText")), 3_000))
        device.findObject(By.focused(true).clazz("android.widget.EditText")).text = password
    }
    assertTrue("Continue enabled", device.wait(Until.hasObject(By.text("继续").enabled(true)), 3_000))
    device.findObject(By.text("继续")).click()
    // Dismiss the fingerprint offer whenever it appears, until the workspace shows.
    val deadline = System.currentTimeMillis() + 15_000
    while (System.currentTimeMillis() < deadline && !device.hasObject(By.desc("笔记"))) {
        device.findObject(By.text("以后再说"))?.click()
        device.wait(Until.hasObject(By.desc("笔记")), 1_000)
    }
    if (!device.hasObject(By.desc("笔记"))) device.dumpWindowHierarchy(java.io.File(androidx.test.platform.app.InstrumentationRegistry.getInstrumentation().targetContext.getExternalFilesDir(null), "onboarding-failure.xml"))
    assertTrue("Workspace after onboarding", device.hasObject(By.desc("笔记")))
}

/** Creates a note from the notes page (the default destination) and returns to the list. */
internal fun createNote(device: UiDevice, title: String) {
    assertTrue(device.wait(Until.hasObject(By.text("新建")), 10_000))
    device.findObject(By.text("新建")).click()
    assertTrue(device.wait(Until.hasObject(By.text("保存")), 5_000))
    // The rich editor's WebView adds its own input later; focus the title field through its
    // placeholder, then type into whatever has focus.
    assertTrue(device.wait(Until.hasObject(By.text("标题")), 5_000))
    device.findObject(By.text("标题")).click()
    assertTrue(device.wait(Until.hasObject(By.focused(true).clazz("android.widget.EditText")), 3_000))
    device.findObject(By.focused(true).clazz("android.widget.EditText")).text = title
    assertTrue("Title typed", device.wait(Until.hasObject(By.text(title)), 5_000))
    device.findObject(By.text("保存")).click()
    val saved = device.wait(Until.hasObject(By.text(title)), 5_000)
    if (!saved) device.dumpWindowHierarchy(java.io.File(androidx.test.platform.app.InstrumentationRegistry.getInstrumentation().targetContext.getExternalFilesDir(null), "create-note-failure.xml"))
    assertTrue("Saved note appears in the list", saved)
}

/** Opens an item from the list and moves it to Trash through its more menu. */
internal fun moveToTrash(device: UiDevice, title: String) {
    device.findObject(By.text(title)).click()
    assertTrue(device.wait(Until.hasObject(By.desc("更多操作")), 5_000))
    device.findObject(By.desc("更多操作")).click()
    assertTrue(device.wait(Until.hasObject(By.text("移到回收站")), 5_000))
    device.findObject(By.text("移到回收站")).click()
    assertTrue(device.wait(Until.hasObject(By.text("移到回收站？")), 5_000))
    device.findObject(By.text("删除")).click()
    assertTrue(device.wait(Until.gone(By.text("移到回收站？")), 5_000))
}

internal fun openTrash(device: UiDevice) {
    // The drawer may ignore a tap while a dialog is still fading out; retry until it opens.
    repeat(5) {
        if (device.hasObject(By.text("回收站"))) return@repeat
        device.wait(Until.hasObject(By.desc("打开导航")), 3_000)
        device.findObject(By.desc("打开导航"))?.click()
        device.wait(Until.hasObject(By.text("回收站")), 2_000)
    }
    assertTrue("Drawer shows Trash", device.hasObject(By.text("回收站")))
    // Taps during the drawer's opening animation can be dropped; retry until Trash shows.
    repeat(5) {
        if (device.hasObject(By.text("搜索回收站"))) return
        android.os.SystemClock.sleep(400)
        device.findObject(By.text("回收站"))?.click()
        device.wait(Until.hasObject(By.text("搜索回收站")), 2_000)
    }
    assertTrue("Trash page", device.hasObject(By.text("搜索回收站")))
}

/** Leaves a detail page until the bottom navigation is visible again. */
internal fun backToNavigation(device: UiDevice) {
    repeat(3) {
        if (device.hasObject(By.desc("笔记"))) return
        device.pressBack()
        device.wait(Until.hasObject(By.desc("笔记")), 2_000)
    }
    assertTrue("Bottom navigation", device.hasObject(By.desc("笔记")))
}
