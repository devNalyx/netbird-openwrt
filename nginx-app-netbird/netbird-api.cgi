#!/bin/sh
# NetBird JSON API CGI
# Deploy to: /www/cgi-bin/netbird-api  (chmod +x)
# GET  → status JSON
# POST → action JSON (action= in url-encoded body)

LOG="/var/log/netbird/client.log"
LOCK="/var/run/netbird-cgi.lock"

MGMT_URL=$(uci get netbird.@connection[0].management_url 2>/dev/null || echo "https://your-netbird-server.example.com:443")
API_TOKEN=$(uci get netbird.@connection[0].api_token 2>/dev/null || true)
ROUTE_ID=$(uci get netbird.@connection[0].route_id 2>/dev/null || true)

urldecode() { printf '%b' "$(echo "$1" | sed 's/+/ /g;s/%/\\x/g')" 2>/dev/null || echo "$1"; }
get_field()  { echo "$2" | grep -o "${1}=[^&]*" | head -1 | cut -d= -f2-; }

# Escape a value for embedding in a JSON string (single line only).
json_str() {
    printf '%s' "$1" | tr -cd '\11\12\40-\176' | awk '{
        gsub(/\\/, "\\\\")
        gsub(/"/, "\\\"")
        printf "%s", $0
    }'
}

update_hosts() {
    local url="$1"
    local host
    host=$(echo "$url" | sed 's|https://||;s|:.*||;s|/.*||')
    [ -z "$host" ] && return
    local ip
    ip=$(nslookup "$host" 8.8.8.8 2>/dev/null | \
         grep 'Address:' | grep -v '8\.8\.8\.' | awk '{print $2}' | head -1)
    [ -z "$ip" ] && return
    sed -i "/ $host$/d" /etc/hosts 2>/dev/null
    echo "$ip $host" >> /etc/hosts
}

ensure_daemon() {
    [ -S /var/run/netbird.sock ] && return
    wait_for_death 10
    rm -f /var/run/netbird.sock
    mkdir -p /var/log/netbird /var/lib/netbird
    /usr/bin/netbird service run --log-file "$LOG" --log-level info &
    i=0
    while [ ! -S /var/run/netbird.sock ] && [ $i -lt 15 ]; do
        sleep 1; i=$((i+1))
    done
}

# Wait up to $1 seconds for all `netbird` processes to actually exit (it can be
# slow to exit or ignore the signal mid-shutdown) before starting a new one.
# A fixed sleep here is what let two daemons run at once and race for wt0 /
# the NETBIRD-* iptables chains — see README Troubleshooting: "Chain already exists".
#
# NOTE: this box's BusyBox has no `pkill` applet at all — `pkill -x netbird`
# silently no-ops (command not found, swallowed by 2>/dev/null) instead of
# failing loudly, which is what let a killed-in-name-only daemon keep running
# alongside a freshly-started one. `pgrep` and `killall` ARE present; use those.
wait_for_death() {
    local max="${1:-10}" i=0
    killall -q netbird 2>/dev/null
    while pgrep -x netbird >/dev/null 2>&1 && [ "$i" -lt "$max" ]; do
        sleep 1; i=$((i+1))
    done
    killall -q -9 netbird 2>/dev/null
    true
}

json_ok()  { printf 'Content-Type: application/json\r\n\r\n{"ok":true,"action":"%s"}' "$1"; exit 0; }
json_err() { printf 'Content-Type: application/json\r\n\r\n{"ok":false,"error":"%s"}' "$1"; exit 0; }

# Lock helpers (directory for atomicity, file inside for PID)
lock_acquire() {
    if mkdir "$LOCK" 2>/dev/null; then
        echo $$ > "$LOCK/pid"
        return 0
    fi
    # Check if holder is still alive
    local pid
    pid=$(cat "$LOCK/pid" 2>/dev/null)
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        return 1   # genuinely busy
    fi
    # Stale lock — holder died without cleanup
    rm -rf "$LOCK"
    mkdir "$LOCK" 2>/dev/null && echo $$ > "$LOCK/pid"
}

# ── POST: actions ─────────────────────────────────────────────────────────────
if [ "$REQUEST_METHOD" = "POST" ]; then
    if ! lock_acquire; then
        json_err "busy"
    fi
    # No trap here: backgrounded actions below hold the lock themselves (via a
    # trap inside their subshell + overwriting $LOCK/pid with the subshell's
    # own PID) so a second click can't overlap a teardown/restart still in
    # flight. Synchronous branches release the lock explicitly before exit.
    read -r -n "${CONTENT_LENGTH:-0}" POST_DATA
    ACTION=$(get_field "action" "$POST_DATA")

    case "$ACTION" in

        quick_setup)
            NEW_URL=$(urldecode "$(get_field "mgmt_url" "$POST_DATA")")
            NEW_KEY=$(urldecode "$(get_field "setup_key" "$POST_DATA")")
            [ -n "$NEW_URL" ] && {
                uci set "netbird.@connection[0].management_url=$NEW_URL"
                MGMT_URL="$NEW_URL"
                uci commit netbird
            }
            (
                trap 'rm -rf "$LOCK"' EXIT
                update_hosts "$MGMT_URL"
                ensure_daemon
                /usr/bin/netbird down >/dev/null 2>&1 || true
                sleep 1
                if [ -n "$NEW_KEY" ]; then
                    /usr/bin/netbird up \
                        --management-url "$MGMT_URL" \
                        --setup-key "$NEW_KEY" \
                        --disable-client-routes >/dev/null 2>&1
                else
                    /usr/bin/netbird up \
                        --management-url "$MGMT_URL" \
                        --disable-client-routes >/dev/null 2>&1
                fi
                [ -n "$API_TOKEN" ] && ( sleep 20; /usr/libexec/netbird-setup-api.sh ) &
            ) &
            echo $! > "$LOCK/pid"
            json_ok "quick_setup"
            ;;

        connect)
            (
                trap 'rm -rf "$LOCK"' EXIT
                ensure_daemon
                /usr/bin/netbird up --management-url "$MGMT_URL" \
                    --disable-client-routes >/dev/null 2>&1
            ) &
            echo $! > "$LOCK/pid"
            json_ok "connect"
            ;;

        disconnect)
            /usr/bin/netbird down >/dev/null 2>&1
            rm -rf "$LOCK"
            json_ok "disconnect"
            ;;

        restart)
            (
                trap 'rm -rf "$LOCK"' EXIT
                wait_for_death 10
                rm -f /var/run/netbird.sock
                mkdir -p /var/log/netbird /var/lib/netbird
                /usr/bin/netbird service run \
                    --log-file "$LOG" --log-level info &
                i=0; while [ ! -S /var/run/netbird.sock ] && [ $i -lt 15 ]; do
                    sleep 1; i=$((i+1))
                done
                /usr/bin/netbird up \
                    --management-url "$MGMT_URL" --disable-client-routes >/dev/null 2>&1
            ) &
            echo $! > "$LOCK/pid"
            json_ok "restart"
            ;;

        toggle_exit)
            (
                trap 'rm -rf "$LOCK"' EXIT
                [ -n "$API_TOKEN" ] && [ -n "$ROUTE_ID" ] && \
                    /usr/libexec/netbird-toggle-exit.sh >/dev/null 2>&1
            ) &
            echo $! > "$LOCK/pid"
            json_ok "toggle_exit"
            ;;

        save_token)
            NEW_TOKEN=$(urldecode "$(get_field "api_token" "$POST_DATA")")
            if [ -n "$NEW_TOKEN" ] && [ "$NEW_TOKEN" != "KEEP" ]; then
                uci set "netbird.@connection[0].api_token=$NEW_TOKEN"
                uci commit netbird
                ( trap 'rm -rf "$LOCK"' EXIT; sleep 3; /usr/libexec/netbird-setup-api.sh ) &
                echo $! > "$LOCK/pid"
            else
                rm -rf "$LOCK"
            fi
            json_ok "save_token"
            ;;

        *)
            rm -rf "$LOCK"
            json_err "unknown action"
            ;;
    esac
fi

# ── GET: status JSON ──────────────────────────────────────────────────────────
DAEMON=$([ -S /var/run/netbird.sock ] && echo "running" || echo "stopped")

# Timeout prevents hang when daemon is unresponsive; 2>&1 captures error msgs
STATUS_RAW=$(timeout 10 /usr/bin/netbird status --detail 2>&1) || STATUS_RAW=""

NB_IP=$(echo "$STATUS_RAW"     | grep '^NetBird IP:'   | head -1 | awk '{print $3}' | cut -d/ -f1)
FQDN=$(echo "$STATUS_RAW"      | grep '^FQDN:'         | head -1 | awk '{print $2}')
MGMT_S=$(echo "$STATUS_RAW"    | grep '^Management:'   | head -1 | cut -d: -f2- | xargs)
PEERS_CNT=$(echo "$STATUS_RAW" | grep '^Peers count:'  | head -1 | awk '{print $3}')
# Anchor to line start and take only the first match to prevent multi-line values
NETWORKS=$(echo "$STATUS_RAW"  | grep '^Networks:'     | head -1 | awk '{$1=""; sub(/^ /,""); print}' | tr -cd '\40-\176')

EXIT_ACTIVE=false
echo "$STATUS_RAW" | grep -q '0\.0\.0\.0/0' && EXIT_ACTIVE=true
TOKEN_SET=false;  [ -n "$API_TOKEN" ] && TOKEN_SET=true
ROUTE_SET=false;  [ -n "$ROUTE_ID" ]  && ROUTE_SET=true

# Escape ALL string fields through json_str — strips control chars + escapes JSON specials
MGMT_ESC=$(json_str "$MGMT_S")
URL_ESC=$(json_str "$MGMT_URL")
FQDN_ESC=$(json_str "$FQDN")
NB_IP_ESC=$(json_str "$NB_IP")
NET_ESC=$(json_str "${NETWORKS:---}")
CNT_ESC=$(json_str "${PEERS_CNT:-0/0}")

# Log tail: strip ALL control chars (incl. ESC/ANSI sequences) before escaping.
# Raw control chars in JSON strings are invalid and break browser JSON.parse().
LOG_ESC=$(tail -20 "$LOG" 2>/dev/null | \
    tr -cd '\11\12\40-\176' | \
    awk '{
        gsub(/\\/, "\\\\")
        gsub(/"/, "\\\"")
        printf "%s\\n", $0
    }' | sed '$ s/\\n$//')

# Build peers JSON array
PEERS_JSON=$(printf '%s\n' "$STATUS_RAW" | awk '
BEGIN { first=1; printf "["; name="" }
/^ [a-zA-Z].*\.selfhosted:/ {
    if (name != "") {
        if (!first) printf ","
        printf "{\"name\":\"%s\",\"ip\":\"%s\",\"status\":\"%s\",\"conn_type\":\"%s\",\"latency\":\"%s\"}",
            name, ip, status, ctype, lat
        first = 0
    }
    name = $1; gsub(/:$/, "", name)
    ip = ""; status = "Idle"; ctype = "-"; lat = "0s"
}
/^  NetBird IP:/   { ip = $3; gsub(/\/[0-9]+$/, "", ip) }
/Status:/          { status = $2 }
/Connection type:/ { ctype = $3 }
/Latency:/         { lat = $2 }
END {
    if (name != "") {
        if (!first) printf ","
        printf "{\"name\":\"%s\",\"ip\":\"%s\",\"status\":\"%s\",\"conn_type\":\"%s\",\"latency\":\"%s\"}",
            name, ip, status, ctype, lat
    }
    printf "]"
}')

printf 'Content-Type: application/json\r\nCache-Control: no-cache\r\n\r\n'
printf '{"daemon":"%s","nb_ip":"%s","fqdn":"%s","mgmt_url":"%s","mgmt_status":"%s",' \
    "$DAEMON" "$NB_IP_ESC" "$FQDN_ESC" "$URL_ESC" "$MGMT_ESC"
printf '"peers_count":"%s","exit_active":%s,"networks":"%s",' \
    "$CNT_ESC" "$EXIT_ACTIVE" "$NET_ESC"
printf '"token_set":%s,"route_id_set":%s,' "$TOKEN_SET" "$ROUTE_SET"
printf '"log_tail":"%s",' "$LOG_ESC"
printf '"peers":%s}' "$PEERS_JSON"
