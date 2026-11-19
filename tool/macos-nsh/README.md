# Mac NSH tools

Run from the repository root. The common entry point remains
`bash tool/nsh_mac.sh check|test|run|package`, with the pinned NSH/rustc and
required huacnlee/cargo bridge.

| Script | Purpose |
| --- | --- |
| `deploy.sh` | Fast local deploy (`--auto` / `--ui-only` 3–5s bundle swap / `--full` signed install + hardlink backup) |
| `signing-cache.sh` | Caches Xcode provisioning profile, entitlements, and signing identity under `private/signing/macos/.cache/` |
| `gui.sh` | Synthetic-vault GUI tests on the task's virtual display |
| `package.sh` | Signed development package and native helpers |
| `install.sh` | Daily installation after a verified private backup |
| `icon.sh` | Shared app icon before signing |
| `memory.sh` | Memory sampling during isolated GUI tests |
| `stage.sh` | Shared staging implementation used by GUI tests and packaging |

Private signing inputs and backups stay under ignored `private/`. Preserve the
loaded extension at `native-test-output/dist`. None of these tools authorizes
launching test apps against the user's vault.
