#!/bin/sh
# NetBird watchdog — cron every 5 min, also called by init.d post-start.
# Responsibilities: reconnect, exit-node ipset rules, TCP keepalive, log rotation.
# Daemon resurrection is handled by procd (respawn param in init.d script).

MGMT=$(uci get netbird.@connection[0].management_url 2>/dev/null || echo "https://your-netbird-server.example.com:443")
LOG="/var/log/netbird/client.log"
SOCK="/var/run/netbird.sock"
LOCK="/var/run/netbird-watchdog.lock"

# ── Prevent concurrent watchdog runs ─────────────────────────────────────────
[ -f "$LOCK" ] && exit 0
echo $$ > "$LOCK"
trap "rm -f $LOCK" EXIT INT TERM

# ── Log rotation: keep last 2000 lines if log exceeds 2 MB ───────────────────
if [ -f "$LOG" ]; then
    sz=$(wc -c < "$LOG" 2>/dev/null || echo 0)
    [ "$sz" -gt 2097152 ] && tail -n 2000 "$LOG" > /tmp/nb.tmp && mv /tmp/nb.tmp "$LOG"
fi

# ── TCP keepalive: prevent ISP CGNAT from timing out the gRPC stream ─────────
# Default Linux values (7200s) are far too long for most ISPs.
sysctl -qw net.ipv4.tcp_keepalive_time=60   2>/dev/null || true
sysctl -qw net.ipv4.tcp_keepalive_intvl=10  2>/dev/null || true
sysctl -qw net.ipv4.tcp_keepalive_probes=3  2>/dev/null || true

# ── If daemon is not running, let procd restart it ────────────────────────────
# Procd handles respawn automatically. Only kick it if procd didn't catch it.
if [ ! -S "$SOCK" ]; then
    /etc/init.d/netbird restart >/dev/null 2>&1
    sleep 10
fi

# ── Reconnect if management is not Connected ──────────────────────────────────
# Covers: CGNAT drops gRPC stream, network changes, stuck-in-Connecting state.
STATUS=$(/usr/bin/netbird status 2>/dev/null)
MGMT_STATE=$(echo "$STATUS" | grep 'Management:' | awk '{print $2}')
if [ -n "$MGMT_STATE" ] && [ "$MGMT_STATE" != "Connected" ]; then
    /usr/bin/netbird up --management-url "$MGMT" --disable-client-routes >/dev/null 2>&1
    sleep 6
fi

# ── Ensure exit-node forwarding rule is present for ALL peer ipsets ───────────
# NetBird creates one nb* ipset per access-control policy. NETBIRD-RT-FWD-IN
# may only have a rule for the first set. Add ACCEPT for every non-empty nb* set
# so all authorized peers can route traffic through the exit node.
if iptables -n -L NETBIRD-RT-FWD-IN >/dev/null 2>&1; then
    for IPSET in $(ipset list -n 2>/dev/null | grep '^nb'); do
        COUNT=$(ipset list "$IPSET" 2>/dev/null | grep -c '^[0-9]')
        [ "$COUNT" -gt 0 ] || continue
        iptables -C NETBIRD-RT-FWD-IN -m set --match-set "$IPSET" src -j ACCEPT 2>/dev/null || \
            iptables -I NETBIRD-RT-FWD-IN 1 -m set --match-set "$IPSET" src -j ACCEPT 2>/dev/null
    done
fi
