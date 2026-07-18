#!/bin/sh
# NetBird status + control + configuration CGI
# Deploy to: /www/cgi-bin/netbird-ui  (chmod +x)
# Accessible via nginx proxy at http://192.168.8.1/netbird/

LOG="/var/log/netbird/client.log"
LOCK="/var/run/netbird-cgi.lock"

MGMT_URL=$(uci get netbird.connection.management_url 2>/dev/null || echo "https://your-netbird-server.example.com")
API_TOKEN=$(uci get netbird.connection.api_token 2>/dev/null || true)
ROUTE_ID=$(uci get netbird.connection.route_id 2>/dev/null || true)

urldecode() { printf '%b' "$(echo "$1" | sed 's/+/ /g;s/%/\\x/g')" 2>/dev/null || echo "$1"; }
get_field()  { echo "$2" | grep -o "${1}=[^&]*" | head -1 | cut -d= -f2-; }
get_qparam() { echo "${QUERY_STRING:-}" | grep -o "${1}=[^&]*" | head -1 | cut -d= -f2-; }

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

# Start daemon if not already running; wait up to 15 s for socket.
# NOTE: no `pkill` applet on this BusyBox — it silently no-ops instead of
# failing. killall/pgrep are present; use those instead.
ensure_daemon() {
    [ -S /var/run/netbird.sock ] && return
    killall -q netbird 2>/dev/null
    sleep 1
    rm -f /var/run/netbird.sock
    mkdir -p /var/log/netbird /var/lib/netbird
    /usr/bin/netbird service run --log-file "$LOG" --log-level info &
    i=0
    while [ ! -S /var/run/netbird.sock ] && [ $i -lt 15 ]; do
        sleep 1; i=$((i+1))
    done
}

# ── POST handler ──────────────────────────────────────────────────────────────
if [ "$REQUEST_METHOD" = "POST" ]; then
    if ! mkdir "$LOCK" 2>/dev/null; then
        printf 'Status: 303 See Other\r\nLocation: /netbird/\r\n\r\n'
        exit 0
    fi
    trap 'rmdir "$LOCK" 2>/dev/null' EXIT
    read -r -n "${CONTENT_LENGTH:-0}" POST_DATA
    ACTION=$(get_field "action" "$POST_DATA")

    case "$ACTION" in

        # ── Primary action: save URL + (optionally) enroll, all in one shot ──
        quick_setup)
            RAW_URL=$(get_field "mgmt_url" "$POST_DATA")
            RAW_KEY=$(get_field "setup_key" "$POST_DATA")
            NEW_URL=$(urldecode "$RAW_URL")
            NEW_KEY=$(urldecode "$RAW_KEY")

            [ -n "$NEW_URL" ] && {
                uci set netbird.connection.management_url="$NEW_URL"
                MGMT_URL="$NEW_URL"
                uci commit netbird
            }

            (
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
            printf 'Status: 303 See Other\r\nLocation: /netbird/?flash=connecting\r\n\r\n'
            exit 0
            ;;

        connect)
            (
                ensure_daemon
                /usr/bin/netbird up --management-url "$MGMT_URL" \
                    --disable-client-routes >/dev/null 2>&1
                ( sleep 15; /usr/libexec/netbird-watchdog.sh ) &
            ) &
            printf 'Status: 303 See Other\r\nLocation: /netbird/?flash=connecting\r\n\r\n'
            exit 0
            ;;

        disconnect)
            /usr/bin/netbird down >/dev/null 2>&1
            printf 'Status: 303 See Other\r\nLocation: /netbird/?flash=disconnected\r\n\r\n'
            exit 0
            ;;

        restart)
            (
                killall -q netbird 2>/dev/null; sleep 3
                killall -q -9 netbird 2>/dev/null; sleep 1
                rm -f /var/run/netbird.sock
                mkdir -p /var/log/netbird /var/lib/netbird
                /usr/bin/netbird service run \
                    --log-file /var/log/netbird/client.log --log-level info &
                i=0; while [ ! -S /var/run/netbird.sock ] && [ $i -lt 15 ]; do
                    sleep 1; i=$((i+1))
                done
                /usr/bin/netbird up \
                    --management-url "$MGMT_URL" --disable-client-routes >/dev/null 2>&1
            ) &
            printf 'Status: 303 See Other\r\nLocation: /netbird/?flash=restarting\r\n\r\n'
            exit 0
            ;;

        toggle_exit)
            [ -n "$API_TOKEN" ] && [ -n "$ROUTE_ID" ] && \
                /usr/libexec/netbird-toggle-exit.sh >/dev/null 2>&1 &
            printf 'Status: 303 See Other\r\nLocation: /netbird/\r\n\r\n'
            exit 0
            ;;

        save_token)
            RAW_TOKEN=$(get_field "api_token" "$POST_DATA")
            NEW_TOKEN=$(urldecode "$RAW_TOKEN")
            [ -n "$NEW_TOKEN" ] && [ "$NEW_TOKEN" != "KEEP" ] && {
                uci set netbird.connection.api_token="$NEW_TOKEN"
                uci commit netbird
                ( sleep 3; /usr/libexec/netbird-setup-api.sh ) &
            }
            printf 'Status: 303 See Other\r\nLocation: /netbird/?flash=saved\r\n\r\n'
            exit 0
            ;;

    esac
    printf 'Status: 303 See Other\r\nLocation: /netbird/\r\n\r\n'
    exit 0
fi

# ── GET: gather status ────────────────────────────────────────────────────────
STATUS_RAW=$(/usr/bin/netbird status --detail 2>&1)
DAEMON=$([ -S /var/run/netbird.sock ] && echo running || echo stopped)
NB_IP=$(echo "$STATUS_RAW"    | grep 'NetBird IP:'    | head -1 | awk '{print $3}')
FQDN=$(echo "$STATUS_RAW"     | grep 'FQDN:'          | awk '{print $2}')
MGMT_S=$(echo "$STATUS_RAW"   | grep 'Management:'    | cut -d: -f2- | xargs)
PEERS=$(echo "$STATUS_RAW"    | grep 'Peers count:'   | awk '{print $3}')
NETWORKS=$(echo "$STATUS_RAW" | grep 'Networks:'      | awk '{print $2}')
EXIT_ACTIVE=0
echo "$STATUS_RAW" | grep -q '0\.0\.0\.0/0' && EXIT_ACTIVE=1

FLASH=$(get_qparam "flash")

# Show setup card when not connected (but not mid-transition)
NEEDS_SETUP=0
if [ "$DAEMON" = "stopped" ] || [ -z "$MGMT_S" ] || [ "$MGMT_S" = "Disconnected" ]; then
    NEEDS_SETUP=1
fi
if [ "$FLASH" = "connecting" ] || [ "$FLASH" = "restarting" ]; then
    NEEDS_SETUP=0
fi

# Shorter refresh during transitions
REFRESH=15
if [ "$FLASH" = "connecting" ] || [ "$FLASH" = "restarting" ]; then
    REFRESH=8
fi

MGMT_URL_ESC=$(echo "$MGMT_URL" | sed 's/&/\&amp;/g;s/"/\&quot;/g')
TOKEN_SET=$([ -n "$API_TOKEN" ] && echo "yes" || echo "no")

DAEMON_BADGE=$([ "$DAEMON" = running ] \
    && echo '<span class="badge up">&#9679; Daemon running</span>' \
    || echo '<span class="badge down">&#9679; Daemon stopped</span>')

EXIT_BTN=""
if [ -n "$API_TOKEN" ] && [ -n "$ROUTE_ID" ]; then
    if [ "$EXIT_ACTIVE" = "1" ]; then
        EXIT_BTN='<form method="post" style="display:inline"><input type="hidden" name="action" value="toggle_exit"><button class="btn" style="background:#f59e0b;color:#fff" type="submit">Disable Exit Node</button></form>'
    else
        EXIT_BTN='<form method="post" style="display:inline"><input type="hidden" name="action" value="toggle_exit"><button class="btn" style="background:#10b981;color:#fff" type="submit">Enable Exit Node</button></form>'
    fi
fi

# ── Flash message ─────────────────────────────────────────────────────────────
FLASH_HTML=""
case "$FLASH" in
    connecting)   FLASH_HTML='<div class="flash flash-info">&#9654; Connecting&hellip; page will refresh in a few seconds.</div>' ;;
    restarting)   FLASH_HTML='<div class="flash flash-info">&#8635; Daemon restarting&hellip; page will refresh in a few seconds.</div>' ;;
    disconnected) FLASH_HTML='<div class="flash flash-warn">&#9632; Disconnected from NetBird.</div>' ;;
    saved)        FLASH_HTML='<div class="flash flash-ok">&#10003; Settings saved.</div>' ;;
esac

# ── Output HTML ───────────────────────────────────────────────────────────────
printf 'Content-Type: text/html\r\n\r\n'

cat << HTMLHEAD
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta http-equiv="refresh" content="${REFRESH}">
<title>NetBird</title>
<style>
*{box-sizing:border-box;margin:0;padding:0}
body{font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;background:#f5f6fa;color:#333;padding:16px;max-width:640px}
h1{font-size:18px;margin-bottom:12px;display:flex;align-items:center;gap:10px;flex-wrap:wrap}
h2{font-size:11px;font-weight:700;margin-bottom:10px;color:#888;text-transform:uppercase;letter-spacing:.8px}
.badge{display:inline-block;padding:3px 10px;border-radius:20px;font-size:12px;font-weight:600}
.up{background:#d4edda;color:#155724}.down{background:#f8d7da;color:#721c24}
.card{background:#fff;border-radius:8px;padding:16px;margin-bottom:12px;box-shadow:0 1px 3px rgba(0,0,0,.08)}
.card.setup-card{border:2px solid #3b82f6;background:#f0f7ff}
.row{display:flex;justify-content:space-between;align-items:baseline;padding:5px 0;border-bottom:1px solid #f0f0f0;font-size:13px;gap:8px}
.row:last-child{border:none}.label{color:#888;flex-shrink:0}.val{font-weight:500;text-align:right;word-break:break-all}
.actions{display:flex;gap:8px;flex-wrap:wrap;margin-top:12px}
.btn{padding:7px 14px;border:none;border-radius:6px;cursor:pointer;font-size:13px;font-weight:600}
.btn-primary{background:#3b82f6;color:#fff}
.btn-danger{background:#ef4444;color:#fff}
.btn-secondary{background:#6b7280;color:#fff}
.btn-connect{background:#2563eb;color:#fff;width:100%;padding:11px;font-size:14px;border-radius:7px;border:none;cursor:pointer;font-weight:700;margin-top:4px}
.btn-connect:active{background:#1d4ed8}
.field{margin-bottom:12px}
.field label{display:block;font-size:12px;font-weight:600;color:#444;margin-bottom:4px}
.field input{width:100%;padding:9px 11px;border:1.5px solid #d1d5db;border-radius:6px;font-size:13px;font-family:monospace;background:#fff}
.field input:focus{outline:none;border-color:#3b82f6;box-shadow:0 0 0 3px rgba(59,130,246,.12)}
.hint{font-size:11px;color:#9ca3af;margin-top:3px}
.hint-inline{font-size:11px;color:#9ca3af;font-weight:400}
.set-badge{background:#d1fae5;color:#065f46;font-size:10px;font-weight:700;padding:1px 6px;border-radius:10px;margin-left:4px}
.unset-badge{background:#fee2e2;color:#991b1b;font-size:10px;font-weight:700;padding:1px 6px;border-radius:10px;margin-left:4px}
details summary{cursor:pointer;font-size:13px;color:#6b7280;padding:4px 0;user-select:none;list-style:none}
details summary::before{content:'▶ '}
details[open] summary::before{content:'▼ '}
details[open] summary{color:#333;font-weight:600;margin-bottom:12px}
hr.div{border:none;border-top:1px solid #e5e7eb;margin:12px 0}
pre{background:#1a1a2e;color:#e0e0e0;padding:10px;border-radius:6px;font-size:11px;overflow-x:auto;max-height:180px;overflow-y:auto;white-space:pre-wrap}
table{width:100%;border-collapse:collapse;font-size:12px}
th{text-align:left;padding:5px 6px;background:#f8f8f8;border-bottom:2px solid #e5e7eb;font-size:11px;text-transform:uppercase;letter-spacing:.4px;color:#888}
td{padding:5px 6px;border-bottom:1px solid #f0f0f0}
.flash{padding:10px 14px;border-radius:6px;margin-bottom:12px;font-size:13px;font-weight:500}
.flash-info{background:#dbeafe;color:#1e40af;border:1px solid #bfdbfe}
.flash-ok{background:#d1fae5;color:#065f46;border:1px solid #a7f3d0}
.flash-warn{background:#fef9c3;color:#854d0e;border:1px solid #fde68a}
code{font-family:monospace;font-size:12px;background:#f3f4f6;padding:1px 5px;border-radius:3px}
</style>
</head>
<body>
<h1>NetBird ${DAEMON_BADGE}</h1>
${FLASH_HTML}
HTMLHEAD

# ── Setup card (shown when not connected) ─────────────────────────────────────
if [ "$NEEDS_SETUP" = "1" ]; then
    cat << SETUPCARD
<div class="card setup-card">
  <h2>&#9881; Setup</h2>
  <form method="post">
    <input type="hidden" name="action" value="quick_setup">
    <div class="field">
      <label>Management Server URL</label>
      <input type="url" name="mgmt_url" value="${MGMT_URL_ESC}"
             placeholder="https://your-netbird-server" required>
    </div>
    <div class="field">
      <label>Setup Key <span class="hint-inline">(NetBird dashboard &#8594; Setup Keys &#8594; Reusable)</span></label>
      <input type="text" name="setup_key"
             placeholder="XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX"
             autocomplete="off" spellcheck="false">
      <div class="hint">Leave blank to reconnect using an existing enrollment.</div>
    </div>
    <button class="btn-connect" type="submit">&#9654;&nbsp; Apply &amp; Connect</button>
  </form>
</div>
SETUPCARD
fi

# ── Status card ───────────────────────────────────────────────────────────────
cat << STATCARD
<div class="card">
  <h2>Connection</h2>
  <div class="row"><span class="label">NetBird IP</span><span class="val"><code>${NB_IP:---}</code></span></div>
  <div class="row"><span class="label">FQDN</span><span class="val"><code>${FQDN:---}</code></span></div>
  <div class="row"><span class="label">Management</span><span class="val">${MGMT_S:-Disconnected}</span></div>
  <div class="row"><span class="label">Server</span><span class="val"><code>${MGMT_URL_ESC}</code></span></div>
  <div class="row"><span class="label">Peers</span><span class="val">${PEERS:-0/0} connected</span></div>
  <div class="row"><span class="label">Exit node</span><span class="val">${NETWORKS:---}</span></div>
  <div class="actions">
    <form method="post" style="display:inline">
      <input type="hidden" name="action" value="connect">
      <button class="btn btn-primary" type="submit">Connect</button>
    </form>
    <form method="post" style="display:inline">
      <input type="hidden" name="action" value="disconnect">
      <button class="btn btn-danger" type="submit">Disconnect</button>
    </form>
    <form method="post" style="display:inline">
      <input type="hidden" name="action" value="restart">
      <button class="btn btn-secondary" type="submit">Restart Daemon</button>
    </form>
    ${EXIT_BTN}
  </div>
</div>
STATCARD

# ── Peers table ───────────────────────────────────────────────────────────────
cat << PEERSHEAD
<div class="card">
  <h2>Peers</h2>
  <table>
    <thead><tr><th>Peer</th><th>IP</th><th>Status</th><th>Latency</th></tr></thead>
    <tbody>
PEERSHEAD

echo "$STATUS_RAW" | awk '
/^ [a-zA-Z].*\.netbird\.selfhosted:/{name=$1; gsub(/:$/,"",name)}
/NetBird IP:/{ip=$3}
/Status:/{status=$2}
/Latency:/{lat=$2; printf "<tr><td><code>%s</code></td><td><code>%s</code></td><td>%s</td><td>%s</td></tr>\n",name,ip,status,lat}
'

# ── Advanced settings (collapsed) + log ──────────────────────────────────────
TOKEN_BADGE=$([ "$TOKEN_SET" = "yes" ] \
    && echo '<span class="set-badge">SET</span>' \
    || echo '<span class="unset-badge">NOT SET</span>')
TOKEN_PH=$([ "$TOKEN_SET" = "yes" ] \
    && echo "Leave blank to keep current" \
    || echo "Paste from NetBird dashboard → avatar → API Tokens")

cat << HTMLFOOT
    </tbody>
  </table>
</div>

<!-- Advanced settings -->
<div class="card">
  <details>
    <summary>Advanced Settings</summary>
    <div class="field" style="margin-top:4px">
      <label>Active Management URL</label>
      <code style="display:block;padding:7px 10px;background:#f3f4f6;border-radius:5px;font-size:12px;word-break:break-all">${MGMT_URL_ESC}</code>
      <div class="hint">To change the server, use the Setup card above — it saves and reconnects in one step.</div>
    </div>
    <hr class="div">
    <form method="post">
      <input type="hidden" name="action" value="save_token">
      <div class="field">
        <label>API Token ${TOKEN_BADGE}</label>
        <input type="password" name="api_token" placeholder="${TOKEN_PH}">
        <div class="hint">Required for the Exit Node toggle button. Leave blank to keep the current value.</div>
      </div>
      <button class="btn btn-primary" type="submit">Save Token</button>
    </form>
  </details>
</div>

<!-- Log -->
<div class="card">
  <h2>Recent Log</h2>
  <pre>$(tail -20 "$LOG" 2>/dev/null || echo '(no log file yet)')</pre>
</div>

<p style="font-size:11px;color:#aaa;margin-top:6px">Refreshes every ${REFRESH}s &nbsp;&#183;&nbsp; $(date '+%H:%M:%S')</p>
</body></html>
HTMLFOOT
