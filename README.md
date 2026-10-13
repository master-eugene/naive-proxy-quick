# NaiveProxy Quick

NaiveProxy Quick installs a NaiveProxy server, a CLI user menu, and optionally a small web panel on a Linux VPS.

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/master-eugene/naive-proxy-quick/master/install.sh)
```

The installer asks for:

1. A domain. This is mandatory; an empty value stops the installation before the server is changed.
2. The NaiveProxy HTTPS port (default `443`).
3. Whether to install the web panel.
4. The panel TCP port (default `51821`) when the panel is selected.
5. Whether to enable BBR and whether the panel should be exposed publicly.

The panel binds to `127.0.0.1` by default. Public unencrypted access requires an explicit confirmation.

Before running it, point the domain's `A` record to the VPS and allow inbound TCP `80` and the chosen proxy port in the provider firewall. Port `80` is required by Caddy for the usual ACME HTTP challenge; `443` is strongly recommended for the proxy because it looks like ordinary HTTPS traffic.

For unattended installation, provide every answer explicitly:

```bash
sudo bash install.sh \
  --domain proxy.example.com \
  --proxy-port 443 \
  --panel yes \
  --panel-port 51821 \
  --panel-access local \
  --bbr yes
```

Use a remote camouflage site instead of the bundled neutral cover page when needed:

```bash
sudo bash install.sh --domain proxy.example.com --decoy-url https://example.org
```

The installer checks DNS, the public VPS address, TCP ports `80` and the selected proxy port, the downloaded Caddy archive checksum, the generated Caddyfile, service health, and finally a real authenticated proxy request. `--skip-dns-check` is available only on `console/install.sh` for intentional NAT or unusual routing setups.

## CLI menu

```bash
sudo npq
```

The menu can list, add, enable, disable, rotate, and remove users. User info includes a Karing-compatible `naive+https://...` link and a sing-box JSON outbound. Scriptable commands are also available:

```bash
sudo npq --json user list
sudo npq --json user add --name phone
sudo npq --json user show --id 1
sudo npq --json user rotate --id 1
```

User state is stored in `/var/lib/naive-proxy-quick/state.json` with mode `0600`. Passwords must remain available to the Caddy forward proxy, so protect root access and server backups. Re-running the installer keeps existing users.

## Web panel

Create an SSH tunnel, then open `http://127.0.0.1:51821` and create the panel administrator on first use:

```bash
ssh -L 51821:127.0.0.1:51821 root@proxy.example.com
```

The panel account is separate from proxy users and persists in the Docker volume.

The panel serves HTTP, so localhost plus an SSH/VPN tunnel is the recommended mode. `--panel-access public` deliberately binds it to `0.0.0.0` and opens the host firewall port, but transport encryption must then be provided separately.

## What is installed

- A pinned and SHA-256-verified official x86-64 Caddy build from `klzgrad/forwardproxy`, which includes the Naive padding layer; non-x86 hosts build it with `xcaddy`.
- `/usr/local/bin/npq` and `naive-proxy.service`.
- `/etc/caddy/Caddyfile`, generated from the shared user state.
- Optional read-only Docker panel with all capabilities dropped except `CHOWN`. It mounts only the shared state, Caddy config, cover site, and the Caddy binary; it does not mount the host root filesystem.

Caddy runs as the unprivileged `caddy` system user with a restricted systemd sandbox. Configuration updates use Caddy's loopback admin API for graceful reloads.

## Optional BBR

BBR is not required. When selected, the installer first verifies kernel support and writes an idempotent `/etc/sysctl.d/99-naive-proxy-quick-bbr.conf`; it does not append repeatedly to `/etc/sysctl.conf`.

The server configuration follows the upstream NaiveProxy recommendation: Caddy's `forward_proxy` handler, Basic authentication, `hide_ip`, `hide_via`, `probe_resistance`, and a normal fallback website.

## Local checks

```bash
bash -n install.sh lib/common.sh console/install.sh docker/install.sh
python3 -m unittest discover -s tests -v
node --check panel/server/index.js
node --check panel/public/app.js
docker compose -f docker/docker-compose.yml config
```

The full installer must be exercised on a disposable Linux VPS because it installs a systemd service, opens firewall ports, obtains a TLS certificate, and optionally installs Docker.
