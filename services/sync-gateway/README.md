# PasswordVault browser relay gateway

Browsers cannot set the existing relay's Authorization header. This separate,
self-hosted service bridges that handshake; it does not change the relay API or
receive vault decryption/signing keys. Tokens are presented in the first WebSocket
frame over TLS, forwarded only to one configured upstream, and are never logged.
The operator of the gateway can see relay tokens and routing metadata; deploy it
under the same administrative trust as your relay. Pairwise vault envelopes remain
encrypted end to end.

Run `npm ci && npm test`, then set `RELAY_UPSTREAM=wss://relay.example/relay/v1/ws`
and `WEB_ORIGINS=https://vault.example` and run `npm start`. Origins are exact and
comma-separated; wildcards and missing Origin are rejected. Terminate TLS with your
reverse proxy and expose only `/connect` as a WebSocket route. The process listens
on localhost:8788 by default. Container use requires a private network plus TLS
proxy. There are no credentials in URLs, query strings or WebSocket subprotocols.

The service fixes the upstream, forbids redirects, times out authentication, caps
frame size, connections, requests per IP and message rate, and closes connections
on excessive buffering. It is an opt-in deployment; no production relay is changed.
