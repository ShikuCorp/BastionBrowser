# BastionBrowser

A Docker container that delivers a secure, locked-down kiosk browser over RDP. Users connect on port **3389** with any RDP client and receive an isolated Chromium session in kiosk mode. Each connection gets its own display, Xorg instance, and throwaway browser profile — torn down the moment the client disconnects.

Designed to sit behind any RDP-capable bastion host (Apache Guacamole, JumpServer, Teleport, etc.) to deliver a controlled browser session to users without requiring HTTP proxying on the bastion side.

## Table of contents

- [How it works](#how-it-works)
- [Quick start](#quick-start)
- [Environment variables](#environment-variables)
- [Security hardening](#security-hardening)
- [Bastion integration](#bastion-integration)
- [URL allowlisting](#url-allowlisting)
- [Custom certificates](#custom-certificates)
- [Docker Compose](#docker-compose)
- [Building from source](#building-from-source)
- [Contributing](#contributing)
- [License](#license)

## How it works

```
RDP client → xRDP (port 3389) → isolated session (Policy=UBC) → Openbox + Chromium
```

xRDP spawns a new session for every connection (`Policy=UBC`). Each session runs a minimal Openbox window manager and Chromium in kiosk mode with a throwaway profile under `/tmp/kiosk-profile-*`. When the client disconnects, the session is killed immediately (`KillDisconnected=1`) and the profile is cleaned up.

## Quick start

```bash
# Generate a hashed password
HASHED=$(openssl passwd -6 'mysecretpassword')

docker run -d -p 3389:3389 \
  -e KIOSK_USERNAME=kiosk \
  -e KIOSK_HASHED_PASSWORD="$HASHED" \
  -e KIOSK_DEFAULT_URL=https://example.com \
  ghcr.io/shikucorp/bastionbrowser
```

Then connect with any RDP client (FreeRDP, mstsc, or via a bastion host) to `localhost:3389`.

## Environment variables

| Variable | Required | Description |
|---|---|---|
| `KIOSK_USERNAME` | **Yes** | RDP login username |
| `KIOSK_HASHED_PASSWORD` | **Yes** | SHA-512 hashed password — generate with `openssl passwd -6` |
| `KIOSK_DEFAULT_URL` | No | URL opened at session start |
| `KIOSK_ALLOWED_URLS` | No | Comma-separated URL allowlist; all other URLs are blocked when set |
| `KIOSK_CUSTOM_CERTS_DIR` | No | Path to a directory of custom CA certificates (`.crt`, `.pem`, `.cer`, `.p12`) |
| `KIOSK_DISABLE_CLIPBOARD` | No | `"true"` disables the RDP clipboard channel |
| `KIOSK_DISABLE_DINOSAUR` | No | `"true"` disables the Chrome offline dinosaur game |
| `KIOSK_GARBAGE_COLLECTOR_INTERVAL` | No | Seconds between orphaned profile cleanups (default: `3600`) |
| `KIOSK_DARK_MODE` | No | `"true"` forces Chromium dark mode |
| `KIOSK_TZ` | No | Timezone (e.g. `Europe/Paris`) |
| `KIOSK_PROXY` | No | Proxy server URL (e.g. `http://proxy.corp:8080`) |
| `KIOSK_PROXY_BYPASS` | No | Semicolon-separated proxy bypass list |

## Security hardening

The container applies several layers of restriction out of the box.

**Chromium enterprise policy** (managed, not user-overridable):
- All extensions blocked
- Developer tools disabled
- Downloads blocked
- Printing disabled
- File picker disabled
- Password manager, autofill, and browser sign-in disabled
- Notifications blocked
- Microphone, camera, and screen capture blocked
- `chrome://` and `file://` URLs blocked

**Session isolation:**
- Each RDP connection creates a dedicated Xorg server, Openbox instance, and throwaway Chromium profile
- No profile data persists across sessions
- Openbox is configured with no keyboard shortcuts and no right-click desktop menu — a Chromium crash cannot expose a terminal

**RDP surface:**
- Clipboard can be disabled via `KIOSK_DISABLE_CLIPBOARD=true`
- Dynamic virtual channels (used for display resizing) are disabled — reduces attack surface
- Chromium runs as an unprivileged OS user (`$KIOSK_USERNAME`), never as root

## Bastion integration

Most bastion hosts support an **AlternateShell** (sometimes called **Start Program**) field on the RDP connection. Set it to the URL you want to open:

```
/usr/local/bin/kiosk.sh https://app.example.com
```

This bypasses the default xRDP session login screen and launches Chromium directly on the target URL. Each RDP connection, even when multiple clients authenticate as the same OS user, gets a fully isolated session.

## URL allowlisting

To restrict Chromium to specific URLs:

```bash
docker run -d -p 3389:3389 \
  -e KIOSK_USERNAME=kiosk \
  -e KIOSK_HASHED_PASSWORD="$HASHED" \
  -e KIOSK_DEFAULT_URL=https://app.example.com \
  -e KIOSK_ALLOWED_URLS="https://app.example.com, https://login.example.com" \
  ghcr.io/shikucorp/bastionbrowser
```

When `KIOSK_ALLOWED_URLS` is set, all other URLs (including `*`) are blocked via Chromium enterprise policy. The allowlist supports [Chrome URL pattern syntax](https://chromeenterprise.google/policies/url-patterns/).

## Custom certificates

Mount a directory of CA certificates and point to it:

```bash
docker run -d -p 3389:3389 \
  -e KIOSK_USERNAME=kiosk \
  -e KIOSK_HASHED_PASSWORD="$HASHED" \
  -e KIOSK_CUSTOM_CERTS_DIR=/certs \
  -v /path/to/certs:/certs:ro \
  ghcr.io/shikucorp/bastionbrowser
```

Supported formats: `.crt`, `.pem` (PEM), `.cer` (DER), `.p12` (PKCS#12, no passphrase).

## Docker Compose

A minimal `compose.yaml` to get started:

```yaml
services:
  bastionbrowser:
    image: ghcr.io/shikucorp/bastionbrowser
    ports:
      - "3389:3389"
    environment:
      KIOSK_USERNAME: kiosk
      KIOSK_HASHED_PASSWORD: "${KIOSK_HASHED_PASSWORD}"
      KIOSK_DEFAULT_URL: https://example.com
      KIOSK_ALLOWED_URLS: "https://example.com"
      KIOSK_DARK_MODE: "true"
      KIOSK_TZ: Europe/Paris
    restart: unless-stopped
```

Store the hashed password in a `.env` file next to `compose.yaml` (never commit it):

```bash
# Generate the hash, then paste the output into .env
openssl passwd -6 'mysecretpassword'
```

```ini
# .env
KIOSK_HASHED_PASSWORD=$6$rounds=...<paste output here>
```

Then run:

```bash
docker compose up -d
```

To mount custom certificates, add a volume:

```yaml
    environment:
      KIOSK_CUSTOM_CERTS_DIR: /certs
    volumes:
      - ./certs:/certs:ro
```

## Building from source

```bash
git clone https://github.com/ShikuCorp/BastionBrowser.git
cd BastionBrowser
docker build -t ghcr.io/shikucorp/bastionbrowser .
```

## Contributing

Contributions are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md) for project structure, design decisions, and development guidelines.

**Bug reports**: use the [bug report template](https://github.com/ShikuCorp/BastionBrowser/issues/new?template=bug_report.yml) — include the image version, your RDP client, the `docker run` command, and the container logs (`docker logs <container>`).

**Feature requests**: use the [feature request template](https://github.com/ShikuCorp/BastionBrowser/issues/new?template=feature_request.yml).

For security vulnerabilities, please **do not** open a public issue — contact the maintainers privately via GitHub's [private vulnerability reporting](https://github.com/ShikuCorp/BastionBrowser/security/advisories/new).

## License

[Apache License 2.0](LICENSE)
