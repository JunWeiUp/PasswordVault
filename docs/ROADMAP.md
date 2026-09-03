# Roadmap

This is a prioritized work list, not a release-date promise.

## Public developer preview

- English-first documentation and bilingual UI.
- Contributor onboarding, issue templates, and repeatable checks.
- Clean all Git references before changing visibility; rotate previously tracked signing credentials.
- Publish clear security limitations and invite review with synthetic data.

## Before production use

- Remove persistent plaintext master passwords from browser storage; use a verified unlock flow and controlled key lifetime.
- Make master-password changes transactional, re-encrypt every relevant record, and preserve sharing identity.
- Version encrypted backup formats, use random salts and a password KDF for new writes, and retain tested legacy reads.
- Review local sync authentication, replay protection, CORS, membership enforcement, and metadata exposure.
- Verify extension message boundaries, pending-save storage, subdomain matching, and lock behavior.
- Validate SQLite loading, Android autofill, backups, restore, and upgrade paths on physical devices.
- Complete an independent security review and publish its scope and findings.

## Broader reach

- More languages and accessibility validation.
- Reproducible release instructions, signing continuity, and store packaging.
- Real screenshots and a short demonstration using a synthetic vault.
- iOS device support and optional desktop runners after platform-specific validation.
