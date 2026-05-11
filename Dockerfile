FROM debian:bookworm-slim

LABEL org.opencontainers.image.authors="Jean-Baptiste BUSSIGNIES <contact@jb.shiku.fr>"
# CIS 4.1: The container intentionally runs as root because the entrypoint must
# create the kiosk OS user, set a hashed password, and start xrdp-sesman/xrdp —
# all of which require root. The kiosk browser session itself runs as the
# unprivileged $KIOSK_USERNAME once xrdp hands off the session.
LABEL org.opencontainers.image.cis-4.1-exception="entrypoint requires root for useradd, chpasswd, xrdp startup; browser session runs as unprivileged kiosk user"

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
 && apt-get upgrade -y \
 && apt-get install -y --no-install-recommends \
    xserver-xorg-core \
    xrdp \
    xorgxrdp \
    openbox \
    chromium \
    fonts-dejavu-core \
    dbus-x11 \
    jq \
    openssl \
 && rm -rf /var/lib/apt/lists/*

# xRDP: Policy=UBC (session per User+BitPerPixel+Connection) gives each
# RDP connection its own isolated display, Xorg instance, and Chromium
# process, even when all clients authenticate as the same OS user.
# KillDisconnected=1 tears the session down immediately on disconnect.
RUN sed -i 's/Policy=Default/Policy=UBC/g' /etc/xrdp/sesman.ini \
 && sed -i 's/KillDisconnected=.*/KillDisconnected=1/' /etc/xrdp/sesman.ini \
 && sed -i 's/DisconnectedTimeLimit=.*/DisconnectedTimeLimit=0/' /etc/xrdp/sesman.ini \
 && sed -i 's/^drdynvc=true/drdynvc=false/' /etc/xrdp/xrdp.ini \
 && sed -i 's/^EnableSyslog=.*/EnableSyslog=false/' /etc/xrdp/xrdp.ini /etc/xrdp/sesman.ini \
 && sed -i 's|^LogFile=.*|LogFile=/dev/stderr|' /etc/xrdp/xrdp.ini /etc/xrdp/sesman.ini \
 && touch /etc/default/locale \
 && mv /usr/lib/chromium/chrome_crashpad_handler \
       /usr/lib/chromium/chrome_crashpad_handler.real

# Chromium policy configuration for kiosk mode
COPY configs/chromium_policy.json /etc/chromium/policies/managed/bastion_policy.json

# Crashpad handler wrapper (see scripts/chrome_crashpad_handler for rationale)
COPY --chmod=755 scripts/chrome_crashpad_handler /usr/lib/chromium/chrome_crashpad_handler

# Kiosk session script (invoked by xRDP per session)
COPY --chmod=755 scripts/kiosk.sh /usr/local/bin/kiosk.sh

# Container entrypoint
COPY --chmod=755 scripts/entry.sh /entry.sh

HEALTHCHECK --interval=30s --timeout=10s --start-period=10s --retries=3 \
  CMD ss -tlnp | grep -q ':3389' || exit 1

EXPOSE 3389
ENTRYPOINT ["/entry.sh"]
