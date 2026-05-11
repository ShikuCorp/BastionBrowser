#!/bin/bash
set -eo pipefail

# ─── Colors (ANSI, supported by docker logs) ─────────────────────────────────
_R=$'\033[0m'
_BOLD=$'\033[1m'
_DIM=$'\033[2m'
_GREEN=$'\033[0;32m'
_YELLOW=$'\033[0;33m'
_RED=$'\033[0;31m'
_CYAN=$'\033[0;36m'
_BLUE=$'\033[0;34m'
_MAGENTA=$'\033[0;35m'

# Prefixes are padded so all log messages align at the same column.
#   [ENTRY]    = 7 chars + 4 spaces = 11
#   [GC]       = 4 chars + 7 spaces = 11
#   [SESMAN]   = 8 chars + 3 spaces = 11
#   [XRDP]     = 6 chars + 5 spaces = 11
_PFX_ENTRY="${_BOLD}${_GREEN}[ENTRY]${_R}    "
_PFX_GC="${_BOLD}${_CYAN}[GC]${_R}       "
_PFX_SESMAN="${_BOLD}${_BLUE}[SESMAN]${_R}   "
_PFX_XRDP="${_BOLD}${_MAGENTA}[XRDP]${_R}     "

log()    { echo -e "${_PFX_ENTRY}$*"; }
warn()   { echo -e "${_PFX_ENTRY}${_YELLOW}$*${_R}" >&2; }
error()  { echo -e "${_PFX_ENTRY}${_RED}$*${_R}" >&2; }
gc_log() { echo -e "${_PFX_GC}$*"; }

# ─── Helpers ─────────────────────────────────────────────────────────────────

POLICY_FILE=/etc/chromium/policies/managed/bastion_policy.json

# In-place update of the Chromium managed policy file via jq.
update_policy() {
  local new_policy
  new_policy=$(jq "$@" "$POLICY_FILE") || { error "jq failed (filter: ${*: -1})"; exit 1; }
  echo "$new_policy" > "$POLICY_FILE"
}

# Starts a process and prefixes every line of its output with a given string.
# Prints the PID of the started process (not the sed consumer).
# Usage: pid=$(start_prefixed PREFIX command [args...])
# Starts a process in a pipeline with sed for log prefixing.
# Stores the background job PID in _PREFIXED_PID (this is sed's PID;
# sed exits automatically when the process closes its end of the pipe).
# The pipe is created by the kernel before any fork, so there is no race.
# Strips \r (xrdp emits \r\n) and blank lines before prepending the prefix.
start_prefixed() {
  local prefix="$1"; shift
  "$@" 2>&1 | sed -u -e 's/\r//' -e '/^[[:space:]]*$/d' -e "s|^|${prefix}|" &
  _PREFIXED_PID=$!
}

# ─── Startup ─────────────────────────────────────────────────────────────────

rm -f /var/run/xrdp.pid /var/run/xrdp-sesman.pid
log "Starting BastionBrowser..."

# ─── Validate required environment variables ─────────────────────────────────

if [[ -z "$KIOSK_USERNAME" || -z "$KIOSK_HASHED_PASSWORD" ]]; then
  error "KIOSK_USERNAME and KIOSK_HASHED_PASSWORD must be set."
  exit 1
fi

if [[ ! "$KIOSK_USERNAME" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then
  error "KIOSK_USERNAME is invalid. Must match ^[a-z_][a-z0-9_-]{0,31}$."
  exit 1
fi

# ─── Create kiosk user ───────────────────────────────────────────────────────

if ! id -u "$KIOSK_USERNAME" >/dev/null 2>&1; then
  log "Creating user '$KIOSK_USERNAME'..."
  useradd -m -s /usr/sbin/nologin "$KIOSK_USERNAME"
  echo "$KIOSK_USERNAME:$KIOSK_HASHED_PASSWORD" | chpasswd -e
fi

# Wire xRDP to launch the kiosk session for this user.
# Root-owned so the kiosk user cannot overwrite it and replace the session.
#
# KIOSK_* environment variables must reach kiosk.sh regardless of how the
# session is started:
#   - Direct RDP (no AlternateShell): xrdp-sesman runs .xsession, which
#     exports them before calling kiosk.sh.
#   - Bastion AlternateShell / "Start Program": xrdp-sesman runs kiosk.sh
#     directly via `sh -c`, bypassing .xsession entirely. PAM reads
#     /etc/environment for all session types, so vars are written there too.
{
  printf '#!/bin/bash\n'
  # Export every KIOSK_* variable that kiosk.sh reads at session time
  for var in KIOSK_DEFAULT_URL KIOSK_DARK_MODE KIOSK_TZ KIOSK_PROXY KIOSK_PROXY_BYPASS; do
    [[ -n "${!var:-}" ]] && printf 'export %s=%q\n' "$var" "${!var}"
  done
  printf 'exec /usr/local/bin/kiosk.sh\n'
} > "/home/$KIOSK_USERNAME/.xsession"
chown root:root "/home/$KIOSK_USERNAME/.xsession"
chmod 755 "/home/$KIOSK_USERNAME/.xsession"

# Write KIOSK_* vars to /etc/environment so pam_env injects them into every
# PAM session, including AlternateShell-initiated ones (bastion Start Program)
# that bypass .xsession.
for var in KIOSK_DEFAULT_URL KIOSK_DARK_MODE KIOSK_TZ KIOSK_PROXY KIOSK_PROXY_BYPASS; do
  [[ -n "${!var:-}" ]] && printf '%s=%s\n' "$var" "${!var}" >> /etc/environment
done

# Locked-down Openbox config — no right-click menu, no keyboard shortcuts.
# Without this, a Chromium crash exposes the default openbox desktop menu
# which can launch terminals or other applications.
# Root-owned so the kiosk user cannot replace them.
OPENBOX_CFG="/home/$KIOSK_USERNAME/.config/openbox"
mkdir -p "$OPENBOX_CFG"
cat > "$OPENBOX_CFG/rc.xml" <<'XMLEOF'
<?xml version="1.0" encoding="UTF-8"?>
<openbox_config xmlns="http://openbox.org/3.4/rc"
                xmlns:xi="http://www.w3.org/2001/XInclude">
  <focus><focusNew>yes</focusNew><followMouse>no</followMouse></focus>
  <placement><policy>Smart</policy></placement>
  <desktops><number>1</number></desktops>
  <!-- No keyboard shortcuts -->
  <keyboard><chainQuitKey>C-g</chainQuitKey></keyboard>
  <!-- No mouse bindings on the desktop root window -->
  <mouse>
    <dragThreshold>8</dragThreshold>
    <doubleClickTime>500</doubleClickTime>
    <screenEdgeWarpTime>400</screenEdgeWarpTime>
    <screenEdgeWarpMouse>false</screenEdgeWarpMouse>
  </mouse>
</openbox_config>
XMLEOF
cat > "$OPENBOX_CFG/menu.xml" <<'XMLEOF'
<?xml version="1.0" encoding="UTF-8"?>
<openbox_menu xmlns="http://openbox.org/3.4/menu">
</openbox_menu>
XMLEOF
chown -R root:root "$OPENBOX_CFG"
chmod -R 755 "$OPENBOX_CFG"

# ─── URL allowlist ───────────────────────────────────────────────────────────

if [[ -n "$KIOSK_ALLOWED_URLS" ]]; then
  log "Configuring URL allowlist..."
  ALLOWED_URLS_JSON=$(echo "$KIOSK_ALLOWED_URLS" | jq -R 'split(",") | map(ltrimstr(" ") | rtrimstr(" "))')
  # shellcheck disable=SC2016  # $urls is a jq variable, not a shell variable
  update_policy --argjson urls "$ALLOWED_URLS_JSON" '(.URLAllowlist = $urls) | (.URLBlocklist = ["*"])'
fi

# ─── Custom certificates ─────────────────────────────────────────────────────

if [[ -n "$KIOSK_CUSTOM_CERTS_DIR" && -d "$KIOSK_CUSTOM_CERTS_DIR" ]]; then
  log "Loading custom certificates from '$KIOSK_CUSTOM_CERTS_DIR'..."

  for cert in "$KIOSK_CUSTOM_CERTS_DIR"/*.crt; do
    [[ -f "$cert" ]] || continue
    cp "$cert" /usr/local/share/ca-certificates/
  done

  for cert in "$KIOSK_CUSTOM_CERTS_DIR"/*.pem; do
    [[ -f "$cert" ]] || continue
    openssl x509 -in "$cert" \
      -out "/usr/local/share/ca-certificates/$(basename "$cert").crt" 2>/dev/null || true
  done

  for cert in "$KIOSK_CUSTOM_CERTS_DIR"/*.cer; do
    [[ -f "$cert" ]] || continue
    openssl x509 -inform DER -in "$cert" \
      -out "/usr/local/share/ca-certificates/$(basename "$cert").crt" 2>/dev/null || true
  done

  for cert in "$KIOSK_CUSTOM_CERTS_DIR"/*.p12; do
    [[ -f "$cert" ]] || continue
    openssl pkcs12 -in "$cert" -nokeys -clcerts -passin pass: \
      -out "/usr/local/share/ca-certificates/$(basename "$cert").crt" 2>/dev/null || true
  done

  update-ca-certificates
  update_policy '.ImportEnterpriseRoots = true'
fi

# ─── RDP clipboard ───────────────────────────────────────────────────────────

if [[ "$KIOSK_DISABLE_CLIPBOARD" == "true" ]]; then
  log "Disabling RDP clipboard..."
  sed -i 's/cliprdr=true/cliprdr=false/g' /etc/xrdp/xrdp.ini
fi

# ─── Chromium dinosaur game ──────────────────────────────────────────────────

if [[ "$KIOSK_DISABLE_DINOSAUR" == "true" ]]; then
  log "Disabling the offline dinosaur game..."
  update_policy '.AllowDinosaurEasterEgg = false'
fi

# ─── Garbage collector ───────────────────────────────────────────────────────

garbage_collector() {
  local interval=${KIOSK_GARBAGE_COLLECTOR_INTERVAL:-3600}

  while true; do
    sleep "$interval"
    gc_log "Scanning for orphaned profiles..."

    for profile_dir in /tmp/kiosk-profile-*; do
      [[ -d "$profile_dir" ]] || continue
      if ! pgrep -f "--user-data-dir=$profile_dir" > /dev/null; then
        gc_log "Removing orphaned profile: ${_DIM}$profile_dir${_R}"
        rm -rf "$profile_dir"
      fi
    done
  done
}

garbage_collector &
GC_PID=$!

# ─── Graceful shutdown ───────────────────────────────────────────────────────

_shutdown() {
  log "Received shutdown signal, stopping services..."
  # Use xrdp's own PID files for clean termination — _PREFIXED_PID holds sed's
  # PID (not the daemon's) when using the pipeline approach in start_prefixed.
  local pid
  if pid=$(cat /var/run/xrdp.pid 2>/dev/null);        then kill -TERM "$pid" 2>/dev/null || true; fi
  if pid=$(cat /var/run/xrdp-sesman.pid 2>/dev/null); then kill -TERM "$pid" 2>/dev/null || true; fi
  if [[ -n "${GC_PID:-}" ]]; then kill -TERM "$GC_PID" 2>/dev/null || true; fi
  wait
}

trap '_shutdown' SIGTERM SIGINT

# ─── Start xRDP ──────────────────────────────────────────────────────────────

start_prefixed "$_PFX_SESMAN" /usr/sbin/xrdp-sesman
SESMAN_PID=$_PREFIXED_PID
log "xrdp-sesman started (PID ${_DIM}${SESMAN_PID}${_R})."

start_prefixed "$_PFX_XRDP" /usr/sbin/xrdp --nodaemon
XRDP_PID=$_PREFIXED_PID
log "xrdp started (PID ${_DIM}${XRDP_PID}${_R}). Container is ready."

wait "$XRDP_PID" || true
log "xrdp exited, container shutting down."