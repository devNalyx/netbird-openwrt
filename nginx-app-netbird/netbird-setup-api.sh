#!/bin/sh
# Background helper: discover peer_id + route_id via API and store in UCI.
# Called automatically from the CGI after token is saved or after enrollment.
# Silent (no stdout) — all output suppressed; exit 0 on any error.

MGMT=$(uci get netbird.@connection[0].management_url 2>/dev/null || echo "https://your-netbird-server.example.com:443")
TOKEN=$(uci get netbird.@connection[0].api_token 2>/dev/null)
[ -z "$TOKEN" ] && exit 0

MY_IP=$(netbird status 2>/dev/null | grep 'NetBird IP:' | awk '{print $3}' | cut -d/ -f1)
[ -z "$MY_IP" ] && exit 0

PEERS_JSON=$(curl -sk --connect-timeout 15 -H "Authorization: Token $TOKEN" "$MGMT/api/peers")
PEER_ID=$(echo "$PEERS_JSON" | tr '\n' ' ' | tr '{' '\n' | \
    grep "\"$MY_IP\"" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)
[ -n "$PEER_ID" ] && uci set "netbird.@connection[0].peer_id=$PEER_ID"

ROUTES_JSON=$(curl -sk --connect-timeout 15 -H "Authorization: Token $TOKEN" "$MGMT/api/routes")
ROUTE_ID=$(echo "$ROUTES_JSON" | tr '\n' ' ' | tr '{' '\n' | \
    grep '0\.0\.0\.0/0' | grep '"enabled"' | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)
[ -n "$ROUTE_ID" ] && uci set "netbird.@connection[0].route_id=$ROUTE_ID"

uci commit netbird 2>/dev/null
