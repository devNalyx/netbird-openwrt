#!/bin/sh
# Start the NetBird daemon on GL-MT3000 (GL.iNet 21.02-SNAPSHOT).
#
# Why not use the procd init script?
# On this GL.iNet firmware, procd sends SIGTERM to the netbird process within
# ~5 seconds of startup. Root cause: GL.iNet's procd layer terminates services
# that don't signal readiness via procd_running (netbird doesn't do this).
#
# The ash background (&) method works correctly: busybox ash does NOT send
# SIGHUP to background jobs when the SSH session exits (unlike bash), so the
# daemon persists after the shell closes.
#
# For boot persistence, add this script to /etc/rc.local (see README.md).

MGMT_URL="https://your-netbird-server.example.com:443"
LOG="/var/log/netbird/client.log"

# Kill any stale instances first
# NOTE: no `pkill` applet on this BusyBox — it silently no-ops instead of
# failing. Use killall (present alongside pgrep) so this actually kills them.
if pgrep -x netbird >/dev/null 2>&1; then
    echo ">> Stopping existing netbird processes..."
    killall -q netbird 2>/dev/null
    sleep 2
fi

rm -f /var/run/netbird.sock
mkdir -p /var/log/netbird /var/lib/netbird

echo ">> Starting NetBird daemon (ash background method)..."
/usr/bin/netbird service run --log-file "$LOG" --log-level info &

# Wait for socket to appear (integer sleep — busybox has no decimal sleep)
i=0
while [ ! -S /var/run/netbird.sock ] && [ "$i" -lt 10 ]; do
    sleep 1
    i=$((i + 1))
done

if [ -S /var/run/netbird.sock ]; then
    echo "   Socket ready. Daemon is up."
    echo "   PID: $(pgrep -x netbird)"
else
    echo "!! Socket did not appear after 10s. Check logs:"
    echo "   tail -20 $LOG"
    exit 1
fi

echo ""
echo ">> To connect (first time or after state reset):"
echo "   netbird up \\"
echo "     --management-url ${MGMT_URL} \\"
echo "     --setup-key YOUR_REUSABLE_KEY \\"
echo "     --disable-client-routes"
echo ""
echo ">> To reconnect (already enrolled, daemon restarted):"
echo "   netbird up --management-url ${MGMT_URL} --disable-client-routes"
