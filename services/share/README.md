# Encrypted temporary sharing

An optional, self-hosted service for encrypted snapshots, not a hosted password
vault. Recipients open a web page without installing an app. The viewing page has
no third-party scripts or analytics and decrypts locally. Its hosting origin remains
trusted code: a compromised deployment could replace the JavaScript. This is not an
independent security audit.

## Configuration

Use Node 24+, then `npm ci`, `npm run check` and `npm test`. Generate two independent
random secrets with `node -e "console.log(require('node:crypto').randomBytes(32).toString('hex'))"`.
Set these variables through your process manager or the ignored `.env` file:

```text
SHARE_SERVICE_SECRET=<independent-random-service-secret>
SHARE_OWNER_TOKENS=<random-owner-access-token>
SHARE_PUBLIC_ORIGIN=https://share.example.com
SHARE_DATA_DIRECTORY=./data
HOST=127.0.0.1
PORT=8787
```

Start with `node --env-file=.env src/main.ts`. Local testing allows
`http://127.0.0.1:8787`; public deployments require HTTPS. Owner tokens may be a
comma-separated list; each owner can manage only their own shares. Tokens are
operator-provisioned, not managed PasswordVault accounts. Keep the service secret
stable across restarts: replacing it invalidates existing authorization hashes.

Optional SMTP variables: `SMTP_HOST`, `SMTP_PORT` (587 by default), `SMTP_SECURE`
(`true` for implicit TLS), `SMTP_USER`, `SMTP_PASSWORD`, and `SMTP_FROM`. STARTTLS
is required otherwise. Without SMTP, recipient-restricted creation fails and clients
disable that option. See [Nodemailer SMTP](https://nodemailer.com/smtp).

`docker compose up --build -d` builds the Node 24 container, persists data in a named
volume and binds port 8787 to loopback. Add an HTTPS proxy using `Caddyfile.example`.
Building/testing the repository does not run this deployment command or modify the
production relay.

For a separately hosted standalone Web app or an extension page, set
`SHARE_ALLOWED_ORIGINS` to the exact comma-separated trusted origins. Wildcards are
not supported. Cross-origin owner requests use bearer authentication without cookies;
recipient viewing and verification remain on the service's own origin.

## API and security boundaries

| Endpoint | Behavior |
| --- | --- |
| `GET /api/capabilities` | SMTP availability, request size and supported lifetimes |
| `POST /api/shares` | Bearer-authenticated creation with version, id, nonce, ciphertext, expiresIn and optional recipientEmail |
| `GET /api/shares` | Current owner's IDs, expiry and recipient-restriction metadata |
| `GET /api/shares/:id` | Ciphertext, gated by expiry and recipient verification |
| `DELETE /api/shares/:id` | Owner-only revoke and deletion |
| `POST /api/shares/:id/challenge` | `{email}` requests a verification code |
| `POST /api/shares/:id/verify` | `{code}` grants a short-lived share-scoped cookie |

The viewer URL is `/s/:id#<base64url-key>`. AES-256-GCM uses a random 32-byte key,
12-byte nonce, 128-bit appended tag and UTF-8 AAD `PasswordVaultShare/v1/:id`.
IDs are 32 lowercase hex characters. Keys are never sent in API requests; accidental
key inclusion is rejected. Native snapshots are limited to 24 MiB plaintext and
service JSON requests to 40 MiB. Attachments are explicitly selected and base64 encoded
inside the encrypted snapshot. Rich notes share a text summary plus selected files;
password history, Passkey private keys and vault settings are not implicitly included.

Allowed lifetimes: one hour, one day, seven days (default), thirty days. Expiry is
checked on every read, independently of periodic cleanup. Codes expire after ten
minutes and five incorrect attempts; successful codes are consumed. Verification
grants HttpOnly, SameSite cookies for at most fifteen minutes, bounded by share expiry.
Revocation removes sessions and challenges. Downloaded/decrypted copies cannot be
revoked. The service/SMTP provider sees the recipient email during delivery; only a
keyed hash is stored in SQLite. Owner tokens, codes, sessions and rate buckets are
also stored as keyed hashes. Metadata uses [Node SQLite](https://nodejs.org/api/sqlite.html).

Rate limits persist across restart. Forwarding headers are not trusted, so reverse
proxies share the network request limit; account for that before high-volume exposure.
Per-owner creation and per-share verification limits remain separate. Each owner has
at most 1000 active shares. Cleanup removes expired data and orphan ciphertext files.
Back up the private data volume together with the service secret.

## Verification

Tests use temporary directories, public synthetic vectors and injected email delivery;
no email is sent. They cover encryption interoperability, owner separation, malformed
requests, expiry, revocation, email gating, exhausted/consumed codes, absent SMTP,
request limits and origin checks. Deployment, live SMTP and independent security review
remain separate from these tests.
