#!/bin/sh
# Manual NetBird full teardown — run this before a clean restart after crashes.
# Kills all netbird processes and removes ALL iptables chains across all tables.

echo "Stopping NetBird..."
pkill -x netbird 2>/dev/null
sleep 3
kill -9 $(pgrep netbird 2>/dev/null) 2>/dev/null
sleep 2

echo "Cleaning iptables..."
for tbl in "" "-t nat" "-t mangle" "-t raw"; do
    iptables-save $tbl 2>/dev/null | grep -E '^-A.+-j NETBIRD' | sed 's/^-A/-D/' | \
        while IFS= read -r rule; do sh -c "iptables $tbl $rule" 2>/dev/null || true; done
    iptables-save $tbl 2>/dev/null | grep '^:NETBIRD' | cut -d' ' -f1 | tr -d ':' | \
        while IFS= read -r chain; do
            iptables $tbl -F "$chain" 2>/dev/null || true
            iptables $tbl -X "$chain" 2>/dev/null || true
        done
done

rm -f /var/run/netbird.sock

# Restore original resolv.conf if NetBird replaced it
if [ -f /etc/resolv.conf.original.netbird ]; then
    cp /etc/resolv.conf.original.netbird /etc/resolv.conf
    echo "resolv.conf restored"
fi

echo "Remaining NETBIRD chains:"
iptables-save 2>/dev/null | grep NETBIRD || echo "  (none — clean)"
iptables-save -t nat 2>/dev/null | grep NETBIRD || true
iptables-save -t mangle 2>/dev/null | grep NETBIRD || true
echo "Done. Run 'netbird service run &' then 'netbird up ...' to restart."
