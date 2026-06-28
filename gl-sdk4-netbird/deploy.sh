#!/bin/sh
# Deploy gl-sdk4-netbird backend to GL-MT3000.
# Installs: UCI config (if not present), procd init script.
# Run from openWrtBird/ directory: sh gl-sdk4-netbird/deploy.sh [user@host]

set -e
ROUTER="${1:-root@192.168.8.1}"
DIR="$(cd "$(dirname "$0")" && pwd)"

push() {
    ssh "$ROUTER" "cat > $2" < "$DIR/$1"
    echo "  OK  $2"
}

echo ">> Deploying gl-sdk4-netbird backend to ${ROUTER}..."

push root/etc/init.d/netbird /etc/init.d/netbird

# Only push UCI config if api_token not already set (preserve live credentials)
HAS_TOKEN=$(ssh "$ROUTER" "uci get netbird.connection.api_token 2>/dev/null | wc -c" 2>/dev/null || echo 0)
if [ "${HAS_TOKEN:-0}" -le 1 ]; then
    push root/etc/config/netbird /etc/config/netbird
    echo "   UCI config installed (no existing credentials found)"
else
    echo "   UCI config skipped (existing credentials preserved)"
fi

# GL.iNet panel integration (sidebar + view bundle)
ssh "$ROUTER" "mkdir -p /usr/share/oui/menu.d /www/i18n /www/views"
push root/usr/share/oui/menu.d/netbirdview.json /usr/share/oui/menu.d/netbirdview.json
push root/www/i18n/gl-sdk4-ui-netbirdview.en.json /www/i18n/gl-sdk4-ui-netbirdview.en.json
push root/www/views/gl-sdk4-ui-netbirdview.common.js.gz /www/views/gl-sdk4-ui-netbirdview.common.js.gz

ssh "$ROUTER" "
    chmod +x /etc/init.d/netbird
    service netbird enable
    service netbird restart
"

echo ""
echo "────────────────────────────────────────────────────────────────"
echo " Deployed. Reload the GL.iNet panel to see NetBird under"
echo " Applications in the sidebar."
echo ""
echo " To set up exit node toggle (if not done):"
echo "   uci set netbird.connection.api_token='YOUR_TOKEN'"
echo "   uci commit netbird"
echo "   sh /tmp/setup-api.sh"
echo "────────────────────────────────────────────────────────────────"
