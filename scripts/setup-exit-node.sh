#!/bin/sh
# Configure GL-MT3000 as a NetBird exit node.
#
# What this does:
#  1. Enables IPv4 forwarding (persistent via sysctl)
#  2. Adds masquerade (NAT) rule on the WAN interface so NetBird peers
#     can route internet traffic through this router
#  3. Configures the OpenWRT firewall to allow forwarded traffic from
#     the NetBird (WireGuard) interface
#
# After running this script:
#  - Go to the NetBird dashboard → Peers → gl-mt3000 → Enable as exit node
#  - In Access Control → Routes, allow desired peers to use this exit node

set -e

# The WireGuard interface created by NetBird — typically wt0 or nb0
# Check with: ip link show | grep wt
NETBIRD_IFACE="wt0"

# Your router's WAN interface (check with: ip route | grep default)
WAN_IFACE=$(ip route show default 2>/dev/null | grep -o 'dev [^ ]*' | awk '{print $2}' | head -1)
if [ -z "$WAN_IFACE" ]; then
    WAN_IFACE="eth1"
    echo ">> Could not detect WAN interface, using default: $WAN_IFACE"
    echo "   Verify with: ip route | grep default"
else
    echo ">> Detected WAN interface: $WAN_IFACE"
fi

echo ">> NetBird WireGuard interface: $NETBIRD_IFACE"

# ── 1. IP forwarding ──────────────────────────────────────────────────────────

echo ">> Enabling IPv4 forwarding..."
sysctl -w net.ipv4.ip_forward=1

# Persist across reboots
SYSCTL_CONF="/etc/sysctl.d/99-netbird-forward.conf"
echo "net.ipv4.ip_forward=1" > "$SYSCTL_CONF"
echo "   Written to $SYSCTL_CONF"

# ── 2. Firewall rules via nftables (OpenWRT 23.05+) ──────────────────────────

# OpenWRT 23.05+ uses nftables via fw4. We add a custom include.
FW4_INCLUDE_DIR="/etc/nftables.d"
FW4_RULES="$FW4_INCLUDE_DIR/99-netbird-exitnode.nft"

if [ -d "$FW4_INCLUDE_DIR" ]; then
    echo ">> Adding nftables rules for exit node (fw4)..."
    cat > "$FW4_RULES" <<EOF
# NetBird exit node rules — managed by setup-exit-node.sh
# Allows NetBird peers to route internet traffic through this router.

table ip netbird_exitnode {
    chain forward {
        type filter hook forward priority 0; policy accept;
        iifname "${NETBIRD_IFACE}" oifname "${WAN_IFACE}" accept comment "NetBird exit: overlay → WAN"
        iifname "${WAN_IFACE}" oifname "${NETBIRD_IFACE}" ct state established,related accept comment "NetBird exit: return traffic"
    }

    chain postrouting {
        type nat hook postrouting priority srcnat; policy accept;
        iifname "${NETBIRD_IFACE}" oifname "${WAN_IFACE}" masquerade comment "NetBird exit: masquerade peers"
    }
}
EOF
    echo "   Written to $FW4_RULES"
    echo ">> Reloading fw4..."
    fw4 reload 2>/dev/null || service firewall restart
else
    # Fallback: iptables (older GL firmware / OpenWRT 21.02)
    echo ">> fw4/nftables not found, falling back to iptables..."
    iptables -t nat -A POSTROUTING -o "$WAN_IFACE" -j MASQUERADE
    iptables -A FORWARD -i "$NETBIRD_IFACE" -o "$WAN_IFACE" -j ACCEPT
    iptables -A FORWARD -i "$WAN_IFACE" -o "$NETBIRD_IFACE" -m state --state ESTABLISHED,RELATED -j ACCEPT

    # Persist via iptables-save (if available)
    if command -v iptables-save >/dev/null 2>&1; then
        iptables-save > /etc/iptables.user
        echo "   Saved to /etc/iptables.user"
        echo "   Add 'iptables-restore < /etc/iptables.user' to /etc/rc.local for persistence"
    fi
fi

# ── 3. OpenWRT UCI firewall zone config ───────────────────────────────────────
# Add NetBird interface to a firewall zone so OpenWRT knows it's trusted.

echo ">> Configuring OpenWRT firewall zone for NetBird interface..."
if uci get firewall.@zone[1] >/dev/null 2>&1; then
    # Add wt0 to the lan zone's network list if not already present
    CURRENT_NETWORKS=$(uci get firewall.@zone[0].network 2>/dev/null || echo "")
    if echo "$CURRENT_NETWORKS" | grep -q "$NETBIRD_IFACE"; then
        echo "   $NETBIRD_IFACE already in firewall zone."
    else
        # Add a dedicated firewall zone for the NetBird interface
        uci add firewall zone
        uci set firewall.@zone[-1].name="netbird"
        uci set firewall.@zone[-1].network="$NETBIRD_IFACE"
        uci set firewall.@zone[-1].input="ACCEPT"
        uci set firewall.@zone[-1].output="ACCEPT"
        uci set firewall.@zone[-1].forward="ACCEPT"
        uci commit firewall
        echo "   Added 'netbird' firewall zone for $NETBIRD_IFACE"
    fi
fi

# ── Done ──────────────────────────────────────────────────────────────────────

echo ""
echo "────────────────────────────────────────────────────────────────"
echo " Exit node configured."
echo ""
echo " Remaining steps (in the NetBird dashboard):"
echo " 1. Peers → gl-mt3000 → toggle 'Exit node' ON"
echo " 2. Access Control → Routes → create a route allowing peers"
echo "    to use this exit node (or enable 'Allow all traffic')"
echo ""
echo " To verify forwarding is active:"
echo "   sysctl net.ipv4.ip_forward   # should print = 1"
echo "   nft list ruleset | grep netbird  # should show masquerade rule"
echo ""
echo " To test from a peer:"
echo "   curl ifconfig.me  # should show your GL-MT3000's public IP"
echo "────────────────────────────────────────────────────────────────"
