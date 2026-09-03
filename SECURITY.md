# Security policy

PasswordVault is a developer preview, not an independently audited password manager. Only the current development branch receives fixes; there is no supported production release yet. See the [security model](docs/SECURITY_MODEL.md) for known limitations.

## Report a vulnerability privately

Use [GitHub private vulnerability reporting](https://github.com/JunWeiUp/PasswordVault/security/advisories/new) when it is enabled. If the form is unavailable, use a private contact explicitly listed by the maintainer on their [GitHub profile](https://github.com/JunWeiUp). Do not disclose exploit details or secrets in a public issue while arranging a private channel.

Include the affected commit/platform, a minimal reproduction using synthetic data, the impact, and any proposed fix. Never send real passwords, live keys, or personal vault backups. No response-time or bounty program is currently promised.

## Release policy

A public production release requires resolution of the documented security blockers, a clean history scan, verified signing, passing CI, and maintainer review. Debug builds are development artifacts. Security-sensitive changes must preserve access to existing encrypted data or provide a tested migration.
