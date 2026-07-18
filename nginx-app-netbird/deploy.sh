#!/bin/sh
# Deploy NetBird UI + daemon config to GL-MT3000.
# Run from openWrtBird/ directory: sh nginx-app-netbird/deploy.sh [user@host]

set -e

ROUTER="${1:-root@192.168.8.1}"
DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$DIR/.." && pwd)"

echo ">> Deploying to ${ROUTER}..."

push() {
    ssh "$ROUTER" "cat > $2" < "$1"
    echo "  OK  $2"
}

# ── Web UI ────────────────────────────────────────────────────────────────────
ssh "$ROUTER" "mkdir -p /www/netbird"
push "$DIR/index.html"             /www/netbird/index.html
push "$DIR/netbird-api.cgi"        /www/cgi-bin/netbird-api
push "$DIR/netbird.conf"           /etc/nginx/gl-conf.d/netbird.conf
push "$DIR/netbird-toggle-exit.sh" /usr/libexec/netbird-toggle-exit.sh
push "$DIR/netbird-setup-api.sh"   /usr/libexec/netbird-setup-api.sh

# ── Watchdog ──────────────────────────────────────────────────────────────────
push "$ROOT/scripts/netbird-watchdog.sh" /usr/libexec/netbird-watchdog.sh
push "$ROOT/scripts/netbird-cleanup.sh"  /usr/libexec/netbird-cleanup.sh

# ── Init.d script (procd — proper OpenWrt service) ────────────────────────────
push "$ROOT/gl-sdk4-netbird/root/etc/init.d/netbird" /etc/init.d/netbird

ssh "$ROUTER" "
    chmod +x /www/cgi-bin/netbird-api \
              /usr/libexec/netbird-toggle-exit.sh \
              /usr/libexec/netbird-setup-api.sh \
              /usr/libexec/netbird-watchdog.sh \
              /usr/libexec/netbird-cleanup.sh \
              /etc/init.d/netbird

    # ── Config persistence ─────────────────────────────────────────────────────
    # /var -> /tmp on OpenWrt: /var/lib/netbird is tmpfs, wiped on reboot.
    # Move config to /etc/netbird (overlay FS) and symlink so the daemon finds it.
    mkdir -p /etc/netbird
    if [ -f /var/lib/netbird/default.json ] && [ ! -L /var/lib/netbird ]; then
        cp /var/lib/netbird/default.json /etc/netbird/default.json
        rm -rf /var/lib/netbird
        ln -s /etc/netbird /var/lib/netbird
        echo '  migrated: /var/lib/netbird -> /etc/netbird'
    elif [ ! -L /var/lib/netbird ]; then
        mkdir -p /var/lib
        rm -rf /var/lib/netbird 2>/dev/null
        ln -s /etc/netbird /var/lib/netbird
        echo '  symlinked: /var/lib/netbird -> /etc/netbird'
    else
        echo '  symlink already in place'
    fi

    # ── Enable procd service ────────────────────────────────────────────────────
    /etc/init.d/netbird enable
    echo '  procd: service enabled (START=90)'

    # ── Remove competing startup from rc.local ──────────────────────────────────
    # rc.local was starting NetBird — this conflicts with procd ownership.
    # Replace with a minimal version: only USB backup restore remains.
    cat > /etc/rc.local << 'RCEOF'
#!/bin/sh
# rc.local — runs after all init.d scripts (after NetBird is already up via procd).

. /lib/functions/gl_util.sh
remount_ubifs

# Restore from USB backup if overlay was wiped by a firmware upgrade
USB_BACKUP=\"/tmp/mountd/disk1_part1/netbird-backup\"
if [ ! -x /usr/bin/netbird ] && [ -f \"\$USB_BACKUP/netbird\" ]; then
    cp \"\$USB_BACKUP/netbird\" /usr/bin/netbird && chmod +x /usr/bin/netbird
fi
if [ ! -f /etc/netbird/default.json ] && [ -f \"\$USB_BACKUP/default.json\" ]; then
    mkdir -p /etc/netbird
    cp \"\$USB_BACKUP/default.json\" /etc/netbird/
fi

exit 0
RCEOF
    chmod +x /etc/rc.local
    echo '  rc.local: NetBird startup removed (procd handles it)'

    # ── Lock cleanup, nginx reload ──────────────────────────────────────────────
    rm -rf /var/run/netbird-cgi.lock
    nginx -t && nginx -s reload
    echo '  nginx reloaded'
"

# ── Watchdog cron (every 5 min) ───────────────────────────────────────────────
echo ">> Installing watchdog cron..."
ssh "$ROUTER" "
    crontab -l 2>/dev/null | grep -q netbird-watchdog || {
        (crontab -l 2>/dev/null; echo '*/5 * * * * /usr/libexec/netbird-watchdog.sh') | crontab -
        /etc/init.d/cron restart 2>/dev/null || true
        echo '  cron installed'
    }
"

# ── TCP keepalive sysctls (persisted to sysctl.conf) ─────────────────────────
echo ">> Applying TCP keepalive sysctls..."
ssh "$ROUTER" "
    grep -q tcp_keepalive_time /etc/sysctl.conf 2>/dev/null || {
        echo 'net.ipv4.tcp_keepalive_time=60'  >> /etc/sysctl.conf
        echo 'net.ipv4.tcp_keepalive_intvl=10' >> /etc/sysctl.conf
        echo 'net.ipv4.tcp_keepalive_probes=3' >> /etc/sysctl.conf
    }
    sysctl -qw net.ipv4.tcp_keepalive_time=60  || true
    sysctl -qw net.ipv4.tcp_keepalive_intvl=10 || true
    sysctl -qw net.ipv4.tcp_keepalive_probes=3 || true
    echo '  keepalive: time=60s intvl=10s probes=3'
"

# ── Run watchdog now ──────────────────────────────────────────────────────────
echo ">> Running watchdog now..."
ssh "$ROUTER" "sh /usr/libexec/netbird-watchdog.sh"

echo ""
echo "────────────────────────────────────────────────────────────────"
echo " Deployed. Open: http://192.168.8.1/netbird/"
echo " (or GL.iNet panel → Applications → NetBird)"
echo ""
echo " Architecture:"
echo "   procd        → starts daemon at boot (START=90), auto-respawn"
echo "   /etc/netbird → persistent config (survives reboots)"
echo "   watchdog     → reconnect + ipset rules every 5 min via cron"
echo ""
echo " API endpoint: http://192.168.8.1/netbird/api"
echo "   GET  → JSON status"
echo "   POST → action (connect|disconnect|restart|quick_setup|toggle_exit|save_token)"
echo "────────────────────────────────────────────────────────────────"
