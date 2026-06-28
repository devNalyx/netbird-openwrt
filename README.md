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
    ├── netbird-cleanup.sh      # Full uninstall
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

## Contributing

PRs welcome — see [CONTRIBUTING.md](CONTRIBUTING.md).

Most useful contributions:
- Testing on other GL.iNet models (GL-MT6000, GL-AXT1800, GL-AX1800)
- Testing on vanilla OpenWrt (non-GL.iNet firmware)
- x86_64 support in `install.sh`
- Package build for OpenWrt's `opkg`

## License

MIT — see [LICENSE](LICENSE).
