#!/bin/sh
# Toggle the NetBird exit node (0.0.0.0/0 route) enabled state via the management API.
# Reads config from UCI. Requires api_token and route_id to be set (run setup-api.sh once).
#
# Safety: own lock file prevents concurrent toggles from rapid double-clicks.
# The CGI fires this in background (&); this script holds the lock until the API call completes.

LOCK="/var/run/netbird-toggle-exit.lock"
[ -f "$LOCK" ] && exit 0
echo $$ > "$LOCK"
trap "rm -f $LOCK" EXIT INT TERM

MGMT=$(uci get netbird.@connection[0].management_url 2>/dev/null || echo "https://your-netbird-server.example.com:443")
TOKEN=$(uci get netbird.@connection[0].api_token 2>/dev/null)
ROUTE_ID=$(uci get netbird.@connection[0].route_id 2>/dev/null)

[ -z "$TOKEN" ]    && echo "netbird-toggle-exit: api_token not set in UCI" >&2 && exit 1
[ -z "$ROUTE_ID" ] && echo "netbird-toggle-exit: route_id not set in UCI"  >&2 && exit 1

# GET current route state from management server
ROUTE=$(curl -sk --connect-timeout 10 \
    -H "Authorization: Token $TOKEN" \
    "$MGMT/api/routes/$ROUTE_ID")

[ -z "$ROUTE" ] && echo "netbird-toggle-exit: empty response from API" >&2 && exit 1

# Detect current enabled value (flatten JSON to avoid multiline issues)
FLAT=$(echo "$ROUTE" | tr '\n' ' ')
ENABLED=$(echo "$FLAT" | tr ',' '\n' | grep '"enabled"' | grep -o 'true\|false' | head -1)
[ -z "$ENABLED" ] && echo "netbird-toggle-exit: could not parse enabled field" >&2 && exit 1

[ "$ENABLED" = "true" ] && NEW="false" || NEW="true"

# PUT back with single-field flip; API ignores read-only fields (id, created_at)
NEW_BODY=$(echo "$FLAT" | sed "s/\"enabled\":$ENABLED/\"enabled\":$NEW/")

curl -sk -X PUT --connect-timeout 10 \
    -H "Authorization: Token $TOKEN" \
    -H "Content-Type: application/json" \
    -d "$NEW_BODY" \
    "$MGMT/api/routes/$ROUTE_ID" > /dev/null

echo "netbird-toggle-exit: set enabled=$NEW for route $ROUTE_ID"
