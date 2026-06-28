#!/bin/sh
# Quick status overview for NetBird on GL-MT3000

MGMT="your-netbird-server.example.com:443"

echo "═══════════════════════════════════════════════"
echo " NetBird Status — GL-MT3000"
echo "═══════════════════════════════════════════════"

echo ""
echo "── NetBird daemon ──────────────────────────────"
if pgrep -x netbird >/dev/null 2>&1; then
    echo "  Status: RUNNING (PID: $(pgrep -x netbird))"
    netbird status 2>/dev/null || echo "  (netbird status unavailable)"
else
    echo "  Status: NOT RUNNING"
    echo "  Start:  sh /tmp/start-daemon.sh"
fi

echo ""
echo "── WireGuard interface ──────────────────────────"
if ip link show wt0 >/dev/null 2>&1; then
    ip link show wt0
    command -v wg >/dev/null 2>&1 && wg show wt0 2>/dev/null || true
else
    echo "  wt0 not present (NetBird not connected)"
fi

echo ""
echo "── Routing table ────────────────────────────────"
ip route show
echo ""
echo "  GOOD: default via ... dev eth0  (WAN, not tunnel)"
echo "  BAD:  default via ... dev wt0   (tunnel hijack — run: netbird down)"

echo ""
echo "── IP forwarding ────────────────────────────────"
FWD=$(sysctl -n net.ipv4.ip_forward 2>/dev/null || cat /proc/sys/net/ipv4/ip_forward)
if [ "$FWD" = "1" ]; then
    echo "  net.ipv4.ip_forward = 1  (exit node mode active)"
else
    echo "  net.ipv4.ip_forward = 0  (client mode, not exit node)"
fi

echo ""
echo "── Management server ────────────────────────────"
HTTP_CODE=$(wget -S --spider "https://${MGMT}/" 2>&1 | grep "HTTP/" | tail -1 | awk '{print $2}')
if [ -n "$HTTP_CODE" ]; then
    echo "  ${MGMT}  → reachable (HTTP ${HTTP_CODE})"
else
    echo "  ${MGMT}  → UNREACHABLE"
fi

echo ""
echo "── Recent logs ──────────────────────────────────"
tail -10 /var/log/netbird/client.log 2>/dev/null || echo "  (no log file)"

echo ""
echo "── Storage ──────────────────────────────────────"
df -h /overlay /tmp 2>/dev/null | head -3
echo "═══════════════════════════════════════════════"
