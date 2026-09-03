# Privacy notes

PasswordVault stores vault data locally and has no project-operated account server. This does not mean that every feature is offline or that all local metadata is encrypted.

- **Vault storage:** SQLite on native platforms; browser storage for Web and the extension. Titles, domains, categories, identifiers, and other metadata may remain readable. Secret fields are encrypted; see the security model for key-storage limitations.
- **WebDAV:** Backup requests and credentials go to the server you configure. Prefer HTTPS. Your server's retention and logging policies apply.
- **Website icons:** Favicon fetching can reveal the domains of stored accounts to icon providers and target websites.
- **Browser extension:** Host access is used to inspect forms and fill credentials. Matching account metadata is cached in extension storage; pending save data and derived keys require particular care. Review the permissions before installing.
- **Local sync and sharing:** Discovery exposes device/service metadata on your local network. Sync uses local HTTP endpoints and experimental access controls; only evaluate it on a trusted test network.
- **Exports and clipboard:** Unencrypted exports and copied secrets are readable by applications with access to those files or the clipboard. Deleting the original vault does not delete exported copies.
- **Diagnostics:** Existing development logging can include identifiers, origins, and network information. Inspect and redact logs before sharing them.

There is no analytics SDK configured by this project. Platform services, browsers, dependencies, or your own hosting provider may collect their own operational data. This document describes the source implementation, not a hosted privacy guarantee.
