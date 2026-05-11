# Contributing to BastionBrowser

Thank you for your interest in contributing. This document covers the project structure, design decisions, and guidelines to help you make effective changes.

## Table of contents

- [Project structure](#project-structure)
- [Architecture](#architecture)
- [Setting up locally](#setting-up-locally)
- [Design decisions](#design-decisions)
- [Common tasks](#common-tasks)
- [Code style](#code-style)
- [Submitting changes](#submitting-changes)

---

## Project structure

| Path | Role |
|---|---|
| `Dockerfile` | Builds on `debian:bookworm-slim`; installs xrdp, xorgxrdp, openbox, chromium |
| `scripts/entry.sh` | Container entrypoint: validates env vars, creates the kiosk OS user, applies runtime policy, starts xRDP |
| `scripts/kiosk.sh` | Per-session script invoked by xrdp-sesman; launches Openbox + Chromium with an isolated throwaway profile |
| `scripts/chrome_crashpad_handler` | Wrapper around the real crashpad binary; injects `--database` when Chromium omits it (see [Design decisions](#design-decisions)) |
| `configs/chromium_policy.json` | Base Chromium enterprise managed policy applied at build time |
| `.hadolint.yaml` | Hadolint configuration; suppresses DL3008 (unpinned apt versions are intentional) |
| `.grype.yaml` | Grype vulnerability scan configuration; ignores unfixed CVEs, documents EPSS usage |
| `.vscode/` | VS Code workspace settings and extension recommendations for hadolint and shellcheck |

---

## Architecture

```
RDP client → xRDP (3389) → new session (Policy=UBC) → kiosk.sh → Openbox + Chromium
```

**Session lifecycle:**
1. An RDP client connects. xRDP creates a new session owing to `Policy=UBC`.
2. xrdp-sesman invokes `kiosk.sh` (directly if an AlternateShell/Start Program is set, otherwise via `.xsession`).
3. `kiosk.sh` creates a throwaway profile under `/tmp/kiosk-profile-XXXXXX`, starts Openbox, then launches Chromium in kiosk mode.
4. When the client disconnects, xrdp kills the session immediately (`KillDisconnected=1`, `DisconnectedTimeLimit=0`). The profile is removed by the `EXIT` trap in `kiosk.sh`; a background garbage collector in `entry.sh` cleans up any orphans.

**Environment variable propagation:**
- `entry.sh` writes all `KIOSK_*` variables to both `/home/$KIOSK_USERNAME/.xsession` (for direct RDP connections) and `/etc/environment` (for AlternateShell/bastion connections that bypass `.xsession`).

---

## Setting up locally

**VS Code**: open the repository folder and accept the *Install recommended extensions* prompt. The workspace already has settings for hadolint (Dockerfile) and shellcheck (shell scripts) configured.

- **hadolint** runs via Docker through `.vscode/bin/hadolint` — no local install needed, but Docker must be running.
- **shellcheck** must be installed locally:

  ```bash
  # Ubuntu / Debian — install shellcheck only (hadolint is not in apt)
  sudo apt install shellcheck
  ```

  If `apt` is unavailable, set `"shellcheck.useBuiltinBinaries": true` in `.vscode/settings.json` and the extension will download a matching binary automatically.

**Build and run:**

```bash
# Build the image
docker build -t bastionbrowser .

# Run with a hashed password
docker run -p 3389:3389 \
  -e KIOSK_USERNAME=kiosk \
  -e KIOSK_HASHED_PASSWORD="$(openssl passwd -6 'testpassword')" \
  -e KIOSK_DEFAULT_URL=https://example.com \
  bastionbrowser

# View logs
docker logs -f <container>
```

Connect with any RDP client to `localhost:3389`. When testing via a bastion's AlternateShell, set the Start Program to `/usr/local/bin/kiosk.sh https://example.com`.

---

## Design decisions

These are non-obvious choices that exist for specific reasons. Please preserve them unless you have a compelling reason to change them, and update this section if you do.

### `Policy=UBC` in xRDP

`Policy=UBC` creates a session per `<User, BitPerPixel, Connection>` tuple. This is what makes true per-connection isolation possible: multiple clients authenticating as the same OS user each get their own Xorg server, Openbox instance, and Chromium process. `Policy=Default` or `Policy=B` would re-attach clients to an existing session instead.

### `KillDisconnected=1` + `DisconnectedTimeLimit=0`

When a client disconnects, the session is torn down immediately. This is intentional: there is no legitimate reason for a kiosk session to persist after the user leaves, and keeping it alive would accumulate profile directories and Xorg processes.

### Chromium invoked as `/usr/lib/chromium/chromium`, not `/usr/bin/chromium`

The `/usr/bin/chromium` Debian wrapper script injects `--enable-gpu-rasterization` into the command line. This conflicts with `--disable-gpu` and produces a black screen. Calling the binary directly avoids this.

### `--disable-gpu` + `--disable-gpu-rasterization`

Chromium is running inside a container without hardware GPU access. These flags prevent it from attempting GPU rendering and falling back to a broken state.

### `--no-sandbox`

Chromium's sandbox requires Linux kernel namespaces. These are typically unavailable inside a Docker container running without `--privileged`. Since the browser already runs as an unprivileged user (`$KIOSK_USERNAME`, not root), the sandbox provides no additional isolation in this context.

### The `chrome_crashpad_handler` wrapper

Chromium 120+ invokes its crashpad handler without the `--database` argument in some code paths. The handler exits immediately with an error when the argument is missing, causing Chromium to receive a SIGTRAP and crash. The wrapper at `scripts/chrome_crashpad_handler` intercepts the call, injects `--database=/tmp/chromium-crashpad-$$`, and forwards to the real binary. The `$$` ensures each session gets its own database path.

### `drdynvc=false` in xRDP

Some RDP clients (including those that implement RDPEDISP for display resizing) send dynamic virtual channel requests. xRDP cannot handle RDPEDISP and logs an error for every single request. Disabling `drdynvc` suppresses this noise. Basic display, input, and clipboard all function without it.

### `EnableSyslog=false` + `LogFile=/dev/stderr`

With `EnableSyslog=true` (the default), xRDP writes log lines via `syslog()` to `/dev/console`, completely bypassing the pipeline in `entry.sh` that prefixes output. Setting both options routes all xRDP output through stderr where the `sed` prefix pipeline can process it.

### dbus in `kiosk.sh`

When xrdp-sesman invokes `kiosk.sh` via AlternateShell, it bypasses the normal `Xsession.d` chain, which includes the script that starts a dbus session bus. Chromium 120+ hangs at startup if no session bus is available. `kiosk.sh` starts one explicitly with `dbus-launch --exit-with-session` before launching Chromium.

### Container runs as root; browser runs as unprivileged user

The entrypoint must run as root to call `useradd`, `chpasswd`, and start xrdp-sesman (which requires root to set up PAM sessions). Once xRDP hands off the session, `kiosk.sh` — and therefore Chromium — run as `$KIOSK_USERNAME`, which is a regular unprivileged user.

---

## Common tasks

**Add a new Chromium policy**

Edit `configs/chromium_policy.json` using a valid [Chromium enterprise policy name](https://chromeenterprise.google/policies/). The file is copied into the image at build time and loaded as a managed policy — users cannot override it.

If the policy needs a runtime value (e.g. a URL configured via an env var), add the mutation in `entry.sh` using `jq`. Never overwrite the file with a heredoc — always use `jq` to make targeted changes so existing keys are preserved.

**Add a new environment variable**

1. Add validation and handling in `entry.sh`.
2. If the value is needed at session time (inside `kiosk.sh`), add it to both the `.xsession` export block and the `/etc/environment` write loop in `entry.sh`.
3. If it is consumed inside `kiosk.sh`, add the logic there.
4. Document the variable in `README.md` and update `CONTRIBUTING.md`.

**Change the RDP port**

Update the `EXPOSE` directive in the `Dockerfile` and the `port=` line in `/etc/xrdp/xrdp.ini` (via a `sed` command in the `RUN` layer).

---

## Code style

- **Shell scripts**: POSIX-compatible where possible; `kiosk.sh` and `entry.sh` use `bash`. Run `shellcheck` before opening a PR.
- **Dockerfile**: Lint with `hadolint`. Use the wrapper so `.hadolint.yaml` is applied consistently:
  ```bash
  ./.vscode/bin/hadolint Dockerfile
  ```
  Chain `apt-get update` and `apt-get install` in the same `RUN` layer; always end with `rm -rf /var/lib/apt/lists/*`.
- **JSON**: Use `jq` for all runtime mutations to `chromium_policy.json`. Do not write JSON with shell string concatenation.
- **Vulnerability scanning**: use Grype to scan the built image locally before pushing:
  ```bash
  docker build -t bastionbrowser .
  grype bastionbrowser
  ```
  Ignore rules are in `.grype.yaml`. Add per-CVE exceptions there with a documented reason rather than bumping the severity threshold.

---

## Submitting changes

1. [Open an issue](https://github.com/ShikuCorp/BastionBrowser/issues) to discuss non-trivial changes before investing time in an implementation.
2. Fork the repository and branch off `main`.
3. Run `./.vscode/bin/hadolint Dockerfile` and `shellcheck scripts/*.sh` locally — the CI workflow runs both. Optionally run `grype <image>` after building to catch new CVEs before pushing.
4. Fill in the pull request template when opening the PR.

For security vulnerabilities, use [GitHub private vulnerability reporting](https://github.com/ShikuCorp/BastionBrowser/security/advisories/new) instead of opening a public issue.
