#!/bin/bash
set -eo pipefail

# ─── Colors (ANSI, supported by docker logs) ─────────────────────────────────
_R=$'\033[0m'
_BOLD=$'\033[1m'
_DIM=$'\033[2m'
_RED=$'\033[0;31m'
_YELLOW=$'\033[0;33m'

# Prefixes are padded so all log messages align at the same column.
#   [KIOSK]    = 7 chars + 4 spaces = 11
#   [CHROMIUM] = 10 chars + 1 space = 11
_PFX_KIOSK="${_BOLD}${_YELLOW}[KIOSK]${_R}    "
_PFX_CHROM="${_DIM}[CHROMIUM]${_R} "

log()   { echo -e "${_PFX_KIOSK}$*"; }
error() { echo -e "${_PFX_KIOSK}${_RED}$*${_R}" >&2; }

# ─── Setup ───────────────────────────────────────────────────────────────────

TMP_PROFILE=$(mktemp -d -t kiosk-profile-XXXXXX)
trap 'rm -rf "$TMP_PROFILE"' EXIT

# Resolve target URL: positional argument takes priority over env var
TARGET_URL="${1:-${KIOSK_DEFAULT_URL:-}}"
if [[ -z "$TARGET_URL" ]]; then
  error "No target URL. Set KIOSK_DEFAULT_URL or pass a URL as the first argument."
  exit 1
fi

log "Session starting for '${_BOLD}${USER:-unknown}${_R}' → ${TARGET_URL}"

if [[ -n "$KIOSK_TZ" ]]; then
  export TZ="$KIOSK_TZ"
fi

# ─── Chromium flags ───────────────────────────────────────────────────────────

CHROMIUM_FLAGS=(
  --kiosk
  --no-first-run
  --no-sandbox
  --disable-dev-shm-usage
  --disable-gpu
  --disable-gpu-rasterization
  --disable-infobars
  --hide-crash-restore-bubble
  "--user-data-dir=$TMP_PROFILE"
)

if [[ "$KIOSK_DARK_MODE" == "true" ]]; then
  CHROMIUM_FLAGS+=(--force-dark-mode)
fi

if [[ -n "$KIOSK_PROXY" ]]; then
  CHROMIUM_FLAGS+=("--proxy-server=$KIOSK_PROXY")
  if [[ -n "$KIOSK_PROXY_BYPASS" ]]; then
    CHROMIUM_FLAGS+=("--proxy-bypass-list=$KIOSK_PROXY_BYPASS")
  fi
fi

# ─── Launch ──────────────────────────────────────────────────────────────────

# xrdp-sesman runs kiosk.sh directly via `sh -c` when an AlternateShell (e.g.
# a bastion's "Start Program") is set, bypassing the Xsession.d chain and the
# 75dbus_dbus-launch script. Without a session bus, Chromium 148+ hangs at
# startup trying to connect to dbus. Start one explicitly here.
if [[ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ]]; then
  eval "$(dbus-launch --sh-syntax --exit-with-session 2>/dev/null)" || true
fi

openbox &
log "Launching Chromium..."
# Call the real binary directly to bypass the /usr/bin/chromium Debian wrapper,
# which sources /etc/chromium.d/ and injects --enable-gpu-rasterization,
# which conflicts with --disable-gpu and causes a black screen.
/usr/lib/chromium/chromium "${CHROMIUM_FLAGS[@]}" "$TARGET_URL" 2>&1 \
  | sed -u "s|^|${_PFX_CHROM}|" || true

log "Session ended for '${_BOLD}${USER:-unknown}${_R}'."
