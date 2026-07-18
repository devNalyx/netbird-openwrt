# netbird-openwrt

> NetBird WireGuard overlay for OpenWrt routers — persistent config, web UI, procd service, exit node.

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![OpenWrt](https://img.shields.io/badge/OpenWrt-21.02+-green.svg)](https://openwrt.org)
[![NetBird](https://img.shields.io/badge/NetBird-0.73+-orange.svg)](https://netbird.io)

A self-contained plugin that runs NetBird as a proper OpenWrt service on GL.iNet routers (and any OpenWrt 21.02+ device). Installs in minutes, survives reboots, and embeds a ZeroTier-style management UI directly into the GL.iNet admin panel.

## Features

- **procd-managed daemon** — auto-starts at boot (`START=90`), auto-respawns on crash; no rc.local hacks
- **Persistent config** — enrollment and WireGuard keys stored in `/etc/netbird/` (overlay FS); survives reboots since OpenWrt's `/var` is tmpfs
- **ZeroTier-style web UI** — status card, peers table with connection type, one-click connect/disconnect/restart, setup key enrollment — embedded in the GL.iNet admin panel at `#/netbirdview`
- **Exit node** — router advertises `0.0.0.0/0` to peers; watchdog maintains `iptables`/`ipset` forwarding rules across all authorized peer sets
- **Stability watchdog** — cron every 5 min: TCP keepalive tuning (prevents CGNAT gRPC stream drops), management reconnect on disconnect, log rotation
- **UCI configuration** — all settings in `/etc/config/netbird`, readable by standard OpenWrt tools
- **API token integration** — optional NetBird API token enables exit node toggle button and auto-discovery of peer/route IDs

## Screenshots

| Connected | Peers |
|-----------|-------|
| *(add screenshot)* | *(add screenshot)* |

## Supported hardware

| Device | SoC | Architecture | Status |
|--------|-----|--------------|--------|
| GL.iNet GL-MT3000 | MediaTek MT7981B | `aarch64_cortex-a53` | ✅ Tested |
| GL.iNet GL-MT6000 | MediaTek MT7986A | `aarch64_cortex-a53` | ⚠️ Should work |
| GL.iNet GL-AXT1800 | IPQ6010 | `ipq60xx` | ⚠️ Untested |
| Any OpenWrt 21.02+ aarch64 | — | `aarch64` | ⚠️ CGI/nginx path works |

> The GL.iNet admin panel integration (`#/netbirdview`) requires GL.iNet firmware v4.x (SDK4).  
> The nginx CGI UI at `/netbird/` works on any OpenWrt router with nginx installed.

## Prerequisites

- GL.iNet router with GL.iNet firmware v4.x (OpenWrt 21.02+)
- A running NetBird management server — self-hosted ([docs](https://docs.netbird.io/selfhosted/selfhosted-guide)) or [netbird.io](https://netbird.io)
- Management server URL **must include an explicit port**: `https://your-server.example.com:443`  
  NetBird's gRPC dialer requires this — omitting the port causes a `missing port in address` error and connection cycling
- SSH access to the router (`root@192.168.8.1`)
- A **Reusable** setup key from the NetBird dashboard

## Installation

### 1. Clone this repo (on your workstation)

```bash
git clone https://github.com/devNalyx/netbird-openwrt.git
cd netbird-openwrt
```

### 2. Install the NetBird binary on the router

```bash
sh scripts/install.sh root@192.168.8.1 https://your-netbird-server.example.com:443
```

This downloads the correct static NetBird binary for `aarch64_cortex-a53`, deploys the procd init script, creates the UCI config skeleton, and installs the watchdog cron job.

### 3. Deploy the web UI

```bash
sh nginx-app-netbird/deploy.sh root@192.168.8.1
```

Deploys: nginx location config, CGI backend, web UI (`index.html`), helper scripts, enables the procd service, migrates config to `/etc/netbird/` (persistent), and cleans up any competing rc.local startup code.

### 4. Enroll with a setup key

Open the GL.iNet admin panel → **Applications → NetBird**  
(or navigate directly to `http://192.168.8.1/netbird/`)

1. Confirm the **Management Server URL** matches your server (with explicit `:443`)
2. Paste a **Reusable** setup key from your NetBird dashboard → Setup Keys
3. Click **Apply**

The router enrolls, saves credentials to `/etc/netbird/default.json` (persistent across reboots), and connects. Future reboots reconnect automatically — no setup key needed again.

## Configuration

UCI config at `/etc/config/netbird`:

```uci
config settings
    option enabled    '1'
    option log_level  'info'

config connection
    option management_url 'https://your-netbird-server.example.com:443'
    option api_token      ''   # Optional: enables Exit Node toggle in UI
    option route_id       ''   # Auto-discovered by setup-api.sh
    option peer_id        ''   # Auto-discovered by setup-api.sh
```

Read/write with UCI:
```bash
uci get netbird.@connection[0].management_url
uci set netbird.@connection[0].management_url='https://your-server.example.com:443'
uci commit netbird
```

## Exit node

The router can act as a NetBird exit node, routing all peer traffic through its WAN connection. To enable the **Exit Node toggle** button in the web UI:

1. Create an API token in your NetBird dashboard (avatar → **API Tokens**)
2. Open the web UI → **Advanced Settings** → paste the API token → **Save**
3. The watchdog automatically discovers your `peer_id` and `route_id` and stores them in UCI

The watchdog ensures `iptables`/`ipset` forwarding rules in `NETBIRD-RT-FWD-IN` cover all authorized peer sets after every NetBird reconnect event.

> **Note:** Run `netbird up` with `--disable-client-routes` on the router — this prevents peer-advertised `0.0.0.0/0` exit-node routes from overwriting the router's own WAN default gateway. The deploy script and init.d script enforce this automatically.

## Architecture

```
Boot sequence
  S90netbird (/etc/init.d/netbird, procd START=90)
    ├── symlink /var/lib/netbird → /etc/netbird  (bypasses tmpfs /var)
    ├── netbird service run --log-file /var/log/netbird/client.log
    └── netbird up --management-url <UCI> --disable-client-routes

Runtime
  wt0 (WireGuard interface)
    ├── gRPC ──────────────────────► NetBird Management Server :443
    └── WebSocket relay (rels://)──► peers (fallback when STUN unavailable)

Web UI stack
  GL.iNet panel → nginx /netbird/ → /www/netbird/index.html  (SPA)
  GL.iNet panel → nginx /netbird/api → uhttpd CGI → netbird-api.cgi

Watchdog (cron */5 * * * *)
  ├── TCP keepalive: time=60s intvl=10s probes=3  (CGNAT gRPC keepalive)
  ├── Management reconnect: netbird up if not Connected
  └── ipset rules: NETBIRD-RT-FWD-IN ACCEPT for all non-empty nb* sets
```

## Project structure

```
netbird-openwrt/
├── nginx-app-netbird/          # Web UI + CGI backend (any OpenWrt with nginx)
│   ├── index.html              # ZeroTier-style management SPA
│   ├── netbird-api.cgi         # JSON API: GET status, POST actions
│   ├── netbird.conf            # nginx location blocks
│   ├── netbird-setup-api.sh    # Auto-discovers peer_id + route_id via API
│   ├── netbird-toggle-exit.sh  # Toggles exit node route via management API
│   ├── setup-api.sh            # Interactive setup-api (run directly on router)
│   └── deploy.sh               # SSH deploy: files + procd enable + config migrate
├── gl-sdk4-netbird/            # GL.iNet SDK4 admin panel integration
│   └── root/
│       ├── etc/config/netbird  # UCI config template
│       ├── etc/init.d/netbird  # procd init script (canonical)
│       └── usr/share/oui/menu.d/netbirdview.json  # Panel sidebar entry
└── scripts/
    ├── install.sh              # Full install: binary + init + UCI + cron
    ├── netbird-watchdog.sh     # Cron watchdog (reconnect, ipset, keepalive)
    ├── netbird-cleanup.sh      # Full teardown before a clean restart (processes + iptables chains)
    ├── setup-exit-node.sh      # One-shot exit node configuration
    ├── start-daemon.sh         # Manual daemon start (debug/fallback)
    └── status.sh               # Quick status overview
```

## Troubleshooting

**UI shows "Connecting..." after reboot**  
Check `tail -20 /var/log/netbird/client.log`. If you see `missing port in address`, the management URL is missing the explicit port — set it via UCI:
```bash
uci set netbird.@connection[0].management_url='https://your-server.example.com:443'
uci commit netbird
/etc/init.d/netbird restart
```

**"LoginFailed" after firmware update or factory reset**  
The overlay FS was wiped. Re-enroll: open the web UI, paste a setup key, click Apply. After that, reboots work automatically again.

**Exit node traffic not forwarding**  
The watchdog re-applies ipset rules every 5 minutes. To fix immediately:
```bash
sh /usr/libexec/netbird-watchdog.sh
```

**Check daemon status**
```bash
netbird status --detail
tail -30 /var/log/netbird/client.log
```

**Router itself can't resolve public hostnames (`wget`/`opkg`/cron scripts fail), but LAN clients still resolve fine**  
NetBird manages `/etc/resolv.conf` when its DNS features are active: it points the router's own system resolver at its embedded DNS proxy (typically `127.0.0.153`) so it can serve split-DNS for `*.netbird.selfhosted`-style peer names, and it's supposed to back up whatever resolver was there before to `/etc/resolv.conf.original.netbird` so it can forward everything else upstream. If that backup file goes missing — e.g. from an unclean shutdown, a manual edit, a factory reset, or restoring `/etc/resolv.conf` from a backup that predates NetBird's own — the proxy has no upstream to forward to, and every hostname lookup outside the NetBird domain fails **for processes running on the router itself only**.

This is easy to miss because it doesn't look like a NetBird problem: LAN devices are untouched, since they resolve via whatever your router already runs for the LAN (dnsmasq, AdGuard Home, Pi-hole, unbound, etc.), which listens on its own address/port and is driven by DHCP, not by the router's own `/etc/resolv.conf`. Only things running locally on the router — this install script's `wget`, `opkg`, the watchdog cron — are affected.

To confirm:
```bash
cat /etc/resolv.conf                              # look for "# Generated by NetBird"
ls /etc/resolv.conf.original.netbird               # missing = confirmed
grep 'failed to restore host DNS settings' /var/log/netbird/client.log
```

To fix, recreate the backup pointing at whatever your router's real local resolver is (its loopback listener, not the WireGuard proxy), then restart NetBird so it picks it up as the DNS proxy's upstream:
```bash
echo 'nameserver 127.0.0.1' > /etc/resolv.conf.original.netbird   # adjust if your local resolver binds elsewhere
sh scripts/netbird-cleanup.sh
netbird service run --log-file /var/log/netbird/client.log --log-level info &
netbird up --management-url <your-mgmt-url> --disable-client-routes
```

**`netbird status` fails with `create firewall manager: ... Chain already exists` after a manual restart or upgrade**  
This means two `netbird service run` processes ended up running at once — usually because a plain `pkill -x netbird` didn't actually kill the previous daemon (it can be slow to exit, or ignore the signal mid-shutdown) before a new one was started. Both instances then try to create the same `NETBIRD-*` iptables chains, and the second one fails. Symptoms: `ps w | grep netbird` shows more `netbird service run` processes than expected, and `netbird status`/`netbird up` error out even though the binary and version are otherwise fine.

Don't just `pkill` and retry — that leaves stale iptables chains behind even after the extra process is gone. Do a full teardown first, then start exactly one instance:
```bash
sh scripts/netbird-cleanup.sh          # kills all netbird processes + flushes all NETBIRD-* chains
netbird service run --log-file /var/log/netbird/client.log --log-level info &
netbird up --management-url <your-mgmt-url> --disable-client-routes
```

The watchdog cron (every 5 min) also checks for this on its own and self-heals — if `pgrep -x netbird` ever finds more than one process, it runs the same cleanup + restart automatically, so a missed click-race can't quietly leak memory for more than one cron cycle. The web UI's restart/connect actions also hold a lock for the full duration of the teardown+restart (not just the HTTP request), so clicking the button again mid-restart is now rejected as "busy" instead of racing a second daemon into existence.

**Root cause of the above, if you're porting this to a different device/firmware:** some BusyBox builds (confirmed on GL.iNet's GL-MT3000 firmware) don't include the `pkill` applet at all — `pkill -x netbird` then silently does nothing (command-not-found, swallowed by `2>/dev/null`) instead of erroring, so the "killed" daemon keeps running while a brand-new one starts next to it. Every script in this repo now kills the daemon with `killall -q netbird` / `killall -q -9 netbird` instead, since `killall` and `pgrep` are present wherever `pkill` is missing. If you're adapting this repo for another router, run `which pkill pgrep killall` on it first and confirm which applets it actually has before assuming any of these process-management calls do what they say.

## Contributing

PRs welcome — see [CONTRIBUTING.md](CONTRIBUTING.md).

Most useful contributions:
- Testing on other GL.iNet models (GL-MT6000, GL-AXT1800, GL-AX1800)
- Testing on vanilla OpenWrt (non-GL.iNet firmware)
- x86_64 support in `install.sh`
- Package build for OpenWrt's `opkg`

## License

MIT — see [LICENSE](LICENSE).
