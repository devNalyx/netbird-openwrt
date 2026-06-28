# Contributing to netbird-openwrt

## Reporting bugs

Use the GitHub issue tracker. Include:
- Router model and firmware version (`cat /etc/openwrt_release`)
- NetBird version (`netbird version`)
- Output of `netbird status --detail`
- Relevant log lines (`tail -50 /var/log/netbird/client.log`)

## Pull requests

1. Fork and create a branch from `main`
2. Test on real hardware — the GL-MT3000 is the reference device
3. Keep shell scripts POSIX-compliant — OpenWrt uses busybox ash, not bash
4. If changing the CGI, verify JSON is valid: `curl -s http://192.168.8.1/netbird/api | python3 -m json.tool`
5. Open the PR describing what you changed and what you tested

## Shell style

- Shebang must be `#!/bin/sh` (not `#!/bin/bash`)
- Quote all variable expansions: `"$VAR"` not `$VAR`
- UCI access always uses the anonymous section form: `netbird.@connection[0].*`
- Test with `shellcheck` where possible

## Architecture invariants

- The procd init script (`gl-sdk4-netbird/root/etc/init.d/netbird`) is the **only** way the daemon should be started — do not re-introduce rc.local startup code
- Config **must** live in `/etc/netbird/` (persistent overlay FS); `/var/lib/netbird` is a symlink there — the symlink is created in `start_service()`
- `--disable-client-routes` is **mandatory** on the router — without it, any peer's `0.0.0.0/0` exit-node advertisement overwrites the WAN default gateway
- All UCI reads use `netbird.@connection[0].*` (anonymous section), never `netbird.connection.*`
