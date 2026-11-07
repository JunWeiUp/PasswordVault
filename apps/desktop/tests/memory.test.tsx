// Memory sampling harness: holds each page still while an outside sampler reads
// the host's footprint (tool/macos-nsh/memory.sh). Real-window runs only; with the
// long-note fixture (examples/seed_long_note.rs) the pinned long note opens first.
import { open, test } from "nsh/test";

const PASSWORD = "synthetic-preview-password";

test("holds pages for memory sampling", async () => {
  const app = await open("../App.tsx", { width: 1440, height: 960, platform: "macos" });
  await app.waitFor("id:unlock-password");
  await app.wait(8000); // locked
  await app.type("id:unlock-password", PASSWORD);
  await app.submit("id:unlock-password");
  await app.waitFor("id:sidebar");
  await app.wait(10000); // notes page, pinned (long) note open
  await app.press("id:nav-accounts");
  await app.wait(8000); // accounts page
}, 180_000);
