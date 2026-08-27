# Security Notes

Omarchy plugins run as unsandboxed code inside the long-lived `omarchy-shell`
process with the permissions of the logged-in user. Review this source before
enabling it.

## Credentials

- OAuth uses PKCE and does not use a client secret.
- Refresh tokens are stored only in `state.json` under a `0700` directory.
- State writes are atomic and reject symlink targets.
- Access and refresh tokens are not command-line arguments or QML properties.
- Tokens are sent only to EVE SSO and ESI over HTTPS.
- Removing a character deletes its stored token from the state file.

## Network access

The backend contacts:

- `https://login.eveonline.com` for OAuth
- `https://esi.evetech.net` for ESI data
- `https://images.evetech.net` only through generated portrait URLs displayed by
  the QML image component

Every ESI request identifies the application with a User-Agent and respects
cache metadata, conditional requests, and endpoint refresh intervals.

## Local callback

The OAuth callback server binds to loopback only, validates the exact callback
path and a cryptographically random state value, accepts one authorization
result, and shuts down after completion or timeout.
