#!/bin/sh
# One-time setup: discover and store peer_id and route_id in UCI.
#
# Run on the router AFTER setting your API token:
#   uci set netbird.connection.api_token='YOUR_TOKEN_HERE'
#   uci commit netbird
#   sh /tmp/setup-api.sh
#
# Generate an API token: NetBird dashboard → top-right avatar → API tokens.
# After this script succeeds, redeploy the CGI to pick up the new config:
#   sh nginx-app-netbird/deploy.sh

MGMT=$(uci get netbird.@connection[0].management_url 2>/dev/null || echo "https://your-netbird-server.example.com:443")
TOKEN=$(uci get netbird.@connection[0].api_token 2>/dev/null)

if [ -z "$TOKEN" ]; then
    echo "ERROR: api_token not set. Run first:"
    echo "  uci set netbird.connection.api_token='YOUR_TOKEN'"
    echo "  uci commit netbird"
    exit 1
fi

# ── Peer ID ───────────────────────────────────────────────────────────────────
echo ">> Discovering peer ID..."

MY_IP=$(netbird status 2>/dev/null | grep 'NetBird IP:' | awk '{print $3}' | cut -d/ -f1)
if [ -z "$MY_IP" ]; then
    echo "ERROR: Cannot get local NetBird IP. Is the daemon connected?"
    exit 1
fi
echo "   Local NetBird IP: $MY_IP"

PEERS_JSON=$(curl -sk --connect-timeout 10 -H "Authorization: Token $TOKEN" "$MGMT/api/peers")
PEER_ID=$(echo "$PEERS_JSON" | tr '\n' ' ' | tr '{' '\n' | \
    grep "\"$MY_IP\"" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)

if [ -z "$PEER_ID" ]; then
    echo "ERROR: Could not find peer with IP $MY_IP in management API response."
    echo "       Ensure the API token has read:peers permission."
    exit 1
fi
echo "   Peer ID: $PEER_ID"
uci set "netbird.@connection[0].peer_id=$PEER_ID"

# ── Route ID ──────────────────────────────────────────────────────────────────
echo ">> Discovering exit route ID (0.0.0.0/0)..."

ROUTES_JSON=$(curl -sk --connect-timeout 10 -H "Authorization: Token $TOKEN" "$MGMT/api/routes")
ROUTE_ID=$(echo "$ROUTES_JSON" | tr '\n' ' ' | tr '{' '\n' | \
    grep '0\.0\.0\.0/0' | grep '"enabled"' | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)

if [ -z "$ROUTE_ID" ]; then
    echo "ERROR: No 0.0.0.0/0 route found."
    echo "       Create an exit node route in the NetBird dashboard first, then re-run."
    exit 1
fi
echo "   Route ID: $ROUTE_ID"
uci set "netbird.@connection[0].route_id=$ROUTE_ID"

# ── Save ──────────────────────────────────────────────────────────────────────
uci commit netbird

echo ""
echo "Done. UCI updated. Now redeploy the CGI:"
echo "  sh nginx-app-netbird/deploy.sh"
