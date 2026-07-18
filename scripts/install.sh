#!/bin/sh
# Install NetBird on GL-MT3000 (aarch64_cortex-a53, OpenWRT/GL.iNet firmware)
# Tested on: OpenWRT 21.02-SNAPSHOT, GL.iNet GL-MT3000 v4.8.1, netbird v0.74.7
#
# GL.iNet custom feeds do NOT include community packages — opkg won't find netbird.
# Downloads the static arm64 binary directly from GitHub releases.
#
# Boot architecture:
#   rc.local → netbird service run & → (wait socket) → netbird up --disable-client-routes
#   Procd init script: deployed but DISABLED (autostart off). Only for `service netbird stop`.
#   Watchdog (cron every 5min): reconnect, exit-node rule, resurrect if daemon crashes.

set -e

NETBIRD_VERSION="0.74.7"
MGMT_URL="${1:-https://your-netbird-server.example.com:443}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo ">> NetBird install for GL-MT3000 (aarch64_cortex-a53)"
echo ">> Version: ${NETBIRD_VERSION}  Management: ${MGMT_URL}"

# ── 1. WireGuard ──────────────────────────────────────────────────────────────
echo ">> Checking WireGuard..."
if lsmod 2>/dev/null | grep -q wireguard; then
    echo "   WireGuard module loaded (GL.iNet bundled kernel module)."
else
    echo "   WireGuard not loaded — attempting modprobe..."
    if ! modprobe wireguard 2>/dev/null; then
        echo "   modprobe failed — trying opkg install kmod-wireguard..."
        opkg update && opkg install kmod-wireguard
    fi
fi

# ── 2. Download binary ────────────────────────────────────────────────────────
# Binary tarball: netbird_{VERSION}_linux_arm64.tar.gz (lowercase "linux", underscores)
DOWNLOAD_URL="https://github.com/netbirdio/netbird/releases/download/v${NETBIRD_VERSION}/netbird_${NETBIRD_VERSION}_linux_arm64.tar.gz"

if command -v netbird >/dev/null 2>&1 && netbird version 2>/dev/null | grep -q "$NETBIRD_VERSION"; then
    echo ">> netbird ${NETBIRD_VERSION} already installed."
else
    echo ">> Downloading netbird v${NETBIRD_VERSION} for linux/arm64..."
    wget -O /tmp/netbird.tar.gz "${DOWNLOAD_URL}"
    echo ">> Extracting..."
    cd /tmp && tar xzf netbird.tar.gz netbird
    mv /tmp/netbird /usr/bin/netbird
    chmod +x /usr/bin/netbird
    rm -f /tmp/netbird.tar.gz
    echo ">> Installed: $(netbird version)"
fi

# ── 3. State directories ──────────────────────────────────────────────────────
mkdir -p /var/lib/netbird /var/log/netbird

# ── 4. Procd init script (disabled — for stop/reference only) ─────────────────
# Autostart is NOT enabled. Daemon boot is handled by rc.local.
# Why: procd respawn + rc.local background daemon = double-daemon conflicts.
# This script enables `service netbird stop` for graceful shutdown.
cat > /etc/init.d/netbird << 'INITEOF'
#!/bin/sh /etc/rc.common
USE_PROCD=1
START=90
STOP=10

start_service() {
    config_load netbird
    local enabled; config_get_bool enabled settings enabled 1
    [ "$enabled" -eq 1 ] || return
    local mgmt_url; config_get mgmt_url connection management_url "MGMT_PLACEHOLDER"
    local log_level; config_get log_level settings log_level "info"
    # No `pkill` applet on GL.iNet's BusyBox — it silently no-ops instead of
    # failing (killall/pgrep are present; use those instead everywhere here).
    killall -q netbird 2>/dev/null; sleep 1
    rm -f /var/run/netbird.sock
    mkdir -p /var/lib/netbird /var/log/netbird
    procd_open_instance
    procd_set_param command /usr/bin/netbird service run \
        --log-file /var/log/netbird/client.log --log-level "$log_level"
    procd_set_param respawn
    procd_set_param stdout 1
    procd_set_param stderr 1
    procd_close_instance
    local mgmt="$mgmt_url"
    ( i=0; while [ ! -S /var/run/netbird.sock ] && [ $i -lt 30 ]; do
        sleep 1; i=$((i+1)); done
      [ -S /var/run/netbird.sock ] && \
        /usr/bin/netbird up --management-url "$mgmt" \
            --disable-client-routes >/dev/null 2>&1 ) &
}

stop_service() {
    /usr/bin/netbird down >/dev/null 2>&1 || true
    killall -q netbird 2>/dev/null || true
    rm -f /var/run/netbird.sock
}
INITEOF
sed -i "s|MGMT_PLACEHOLDER|${MGMT_URL}|g" /etc/init.d/netbird
chmod +x /etc/init.d/netbird
# Disable autostart — rc.local manages the daemon
/etc/init.d/netbird disable 2>/dev/null || true
echo "   Init script deployed (autostart DISABLED)"

# ── 5. Watchdog ───────────────────────────────────────────────────────────────
cat /dev/stdin > /usr/libexec/netbird-watchdog.sh << 'WATCHEOF'
WATCHEOF
# Pipe from local file (run via ssh — copy from script dir)
echo "   NOTE: Deploy watchdog separately via: deploy.sh or scp scripts/netbird-watchdog.sh"

chmod +x /usr/libexec/netbird-watchdog.sh 2>/dev/null || true

# ── 6. Cron job for watchdog ──────────────────────────────────────────────────
CRON_LINE="*/5 * * * * /usr/libexec/netbird-watchdog.sh"
if ! crontab -l 2>/dev/null | grep -qF "netbird-watchdog"; then
    (crontab -l 2>/dev/null; echo "$CRON_LINE") | crontab -
    echo "   Cron job added (every 5 minutes)"
else
    echo "   Cron job already present"
fi

# ── 7. UCI config skeleton ────────────────────────────────────────────────────
if ! uci get netbird.settings >/dev/null 2>&1; then
    uci set netbird.settings=settings
    uci set netbird.settings.enabled=1
    uci set netbird.settings.log_level=info
    uci set netbird.connection=connection
    uci set netbird.connection.management_url="${MGMT_URL}"
    uci commit netbird
    echo "   UCI config created"
fi

# ── 8. rc.local section ───────────────────────────────────────────────────────
# Adds daemon start block if not already present.
# Uses ash background (&) — ash doesn't SIGHUP background jobs on rc.local exit.
if ! grep -q 'netbird service run' /etc/rc.local 2>/dev/null; then
    # Insert before final `exit 0`
    sed -i '/^exit 0/i \
\
# ── NetBird ──────────────────────────────────────────────────────────────────\
mkdir -p /var/log/netbird /var/lib/netbird\
killall -q netbird 2>/dev/null; sleep 1\
rm -f /var/run/netbird.sock\
/usr/bin/netbird service run --log-file /var/log/netbird/client.log --log-level info \&\
i=0; while [ ! -S /var/run/netbird.sock ] \&\& [ $i -lt 30 ]; do sleep 1; i=$((i+1)); done\
MGMT=$(uci get netbird.connection.management_url 2>/dev/null || echo "'"${MGMT_URL}"'")\
[ -S /var/run/netbird.sock ] \&\& /usr/bin/netbird up --management-url "$MGMT" --disable-client-routes\
( sleep 20; /usr/libexec/netbird-watchdog.sh ) \&' /etc/rc.local
    echo "   rc.local updated with daemon start block"
else
    echo "   rc.local already has netbird section — not modified"
fi

echo ""
echo "────────────────────────────────────────────────────────────────"
echo " NetBird installed. Next steps:"
echo ""
echo " 1. Deploy the watchdog (from openWrtBird/ directory):"
echo "    sh nginx-app-netbird/deploy.sh"
echo ""
echo " 2. Start the daemon now (no reboot needed):"
echo "    killall -q netbird 2>/dev/null; sleep 1"
echo "    netbird service run --log-file /var/log/netbird/client.log &"
echo "    netbird up --management-url ${MGMT_URL} --setup-key YOUR_KEY --disable-client-routes"
echo ""
echo " 3. Get a REUSABLE setup key from:"
echo "    ${MGMT_URL}  →  Setup Keys (Reusable type only)"
echo ""
echo " NOTE: --disable-client-routes is required on a router to prevent"
echo " other peers' exit-node routes from overwriting the WAN default route."
echo "────────────────────────────────────────────────────────────────"
