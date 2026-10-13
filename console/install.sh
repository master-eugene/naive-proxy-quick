#!/usr/bin/env bash
if [ -z "${BASH_VERSION:-}" ]; then echo "Run with bash." >&2; exit 1; fi
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/lib/common.sh"
DOMAIN="" PORT="" DECOY_URL="" ENABLE_BBR=0 SKIP_DNS_CHECK=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --domain) [[ $# -ge 2 ]] || die "--domain needs a value."; DOMAIN="$2"; shift 2 ;;
    --port) [[ $# -ge 2 ]] || die "--port needs a value."; PORT="$2"; shift 2 ;;
    --decoy-url) [[ $# -ge 2 ]] || die "--decoy-url needs a value."; DECOY_URL="$2"; shift 2 ;;
    --enable-bbr) ENABLE_BBR=1; shift ;;
    --skip-dns-check) SKIP_DNS_CHECK=1; shift ;;
    *) die "Unknown option: $1" ;;
  esac
done

require_linux_root
DOMAIN="$(ask_domain "$DOMAIN")"
PORT="$(ask_port "NaiveProxy HTTPS port" 443 "$PORT")"
[[ "$PORT" == 443 ]] || warn "Port 443 provides the most ordinary HTTPS appearance. Custom ports may be easier to identify or block."

log "Installing build and runtime packages"
if [[ "$PKG" == apt ]]; then install_packages ca-certificates curl python3 libcap2-bin tar xz-utils procps passwd iproute2;
else install_packages ca-certificates curl python3 libcap tar xz procps-ng shadow-utils iproute; fi

if [[ -n "$DECOY_URL" && "${DECOY_URL,,}" != none ]]; then
  python3 -c 'import sys
from urllib.parse import urlparse
p=urlparse(sys.argv[1])
ok=p.scheme in ("http","https") and p.hostname and not p.username and not p.password and p.path in ("","/") and not p.query and not p.fragment
raise SystemExit(0 if ok else 1)' "$DECOY_URL" || die "Camouflage URL must be an http(s) origin without credentials, path, query, or fragment."
fi

preflight() {
  if port_busy 80 && ! { command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet naive-proxy; }; then
    die "TCP port 80 is in use. Caddy needs it for automatic HTTPS. Stop the conflicting web server or use a compatible front-end setup."
  fi
  [[ "$SKIP_DNS_CHECK" -eq 0 ]] || { warn "Skipping DNS ownership check."; return; }
  local resolved public_ip
  resolved="$(getent ahostsv4 "$DOMAIN" 2>/dev/null | awk '{print $1}' | sort -u)"
  [[ -n "$resolved" ]] || die "${DOMAIN} has no IPv4 address. Create its DNS A record before installing."
  public_ip="$(curl -4fsS --max-time 8 https://api.ipify.org 2>/dev/null || true)"
  if [[ -n "$public_ip" ]] && ! grep -Fxq "$public_ip" <<<"$resolved"; then
    die "${DOMAIN} resolves to $(tr '\n' ' ' <<<"$resolved"), but this VPS reports ${public_ip}. Update DNS or use --skip-dns-check if this is intentional."
  fi
  log "DNS preflight passed for ${DOMAIN}${public_ip:+ (${public_ip})}"
}

enable_bbr() {
  [[ "$ENABLE_BBR" -eq 1 ]] || return
  modprobe tcp_bbr 2>/dev/null || true
  if ! sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -qw bbr; then
    warn "This kernel does not report BBR support; leaving congestion control unchanged."
    return
  fi
  log "Enabling BBR congestion control"
  cat > /etc/sysctl.d/99-naive-proxy-quick-bbr.conf <<'EOF'
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
  sysctl -p /etc/sysctl.d/99-naive-proxy-quick-bbr.conf >/dev/null || warn "The BBR settings were saved but could not be applied immediately."
}

preflight
enable_bbr

build_dir="$(mktemp -d)"
trap 'rm -rf "$build_dir"' EXIT
if [[ "$(uname -m)" == x86_64 || "$(uname -m)" == amd64 ]]; then
  CADDY_NAIVE_VERSION=v2.11.7-naive
  CADDY_NAIVE_SHA256=ac97057c925bb098eb575e7b0cb8bd547d4c5f845b09a3dedfbe34444aa7ae88
  release_url="https://github.com/klzgrad/forwardproxy/releases/download/${CADDY_NAIVE_VERSION}/caddy-forwardproxy-naive.tar.xz"
  log "Downloading the pinned Caddy forwardproxy build (${CADDY_NAIVE_VERSION})"
  curl -fsSL --retry 3 "$release_url" -o "$build_dir/caddy.tar.xz"
  printf '%s  %s\n' "$CADDY_NAIVE_SHA256" "$build_dir/caddy.tar.xz" | sha256sum -c - >/dev/null || die "Caddy archive checksum verification failed."
  tar -xJf "$build_dir/caddy.tar.xz" -C "$build_dir"
  install -m 755 "$build_dir/caddy-forwardproxy-naive/caddy" /usr/local/bin/caddy
else
  warn "No official prebuilt Caddy archive is available for $(uname -m); building locally."
  if [[ "$PKG" == apt ]]; then install_packages git golang-go; else install_packages git golang; fi
  GOBIN=/usr/local/bin go install github.com/caddyserver/xcaddy/cmd/xcaddy@v0.4.7
  (cd "$build_dir" && GOTOOLCHAIN=auto xcaddy build --output caddy --with github.com/caddyserver/forwardproxy=github.com/klzgrad/forwardproxy@v2.11.7-naive)
  install -m 755 "$build_dir/caddy" /usr/local/bin/caddy
fi
/usr/local/bin/caddy list-modules | grep -qx 'http.handlers.forward_proxy' || die "The built Caddy binary does not include forward_proxy."

log "Installing the npq menu and service"
getent group caddy >/dev/null 2>&1 || groupadd --system caddy
id -u caddy >/dev/null 2>&1 || useradd --system --gid caddy --create-home --home-dir /var/lib/caddy --shell /usr/sbin/nologin --comment "Caddy web server" caddy
install -m 755 "$ROOT/console/npq" /usr/local/bin/npq
install -m 644 "$ROOT/console/naive-proxy.service" /etc/systemd/system/naive-proxy.service
mkdir -p /var/lib/naive-proxy-quick /etc/caddy /var/www/naive-proxy-quick
chmod 700 /var/lib/naive-proxy-quick
mkdir -p /var/lib/caddy
chown caddy:caddy /var/lib/caddy
if [[ ! -f /var/www/naive-proxy-quick/index.html ]]; then
  install -m 644 "$ROOT/cover/index.html" /var/www/naive-proxy-quick/index.html
fi

systemctl daemon-reload
init_args=(init --domain "$DOMAIN" --port "$PORT" --no-reload)
[[ -z "$DECOY_URL" ]] || init_args+=(--decoy-url "$DECOY_URL")
/usr/local/bin/npq "${init_args[@]}"
systemctl enable naive-proxy
systemctl restart naive-proxy
open_firewall 80 "Caddy ACME"
open_firewall "$PORT" "NaiveProxy"
if ! systemctl is-active --quiet naive-proxy; then
  journalctl -u naive-proxy -n 60 --no-pager >&2 || true
  die "NaiveProxy did not start. Check that ${DOMAIN} resolves to this server and ports 80/443 are reachable."
fi
log "NaiveProxy is active on ${DOMAIN}:${PORT}"

verify_proxy() {
  local first proxy answer attempt
  first="$(/usr/local/bin/npq --json user list | python3 -c 'import json,sys; print(json.load(sys.stdin)["users"][0]["id"])')"
  proxy="$(/usr/local/bin/npq --json user show --id "$first" | python3 -c 'import json,sys; print(json.load(sys.stdin)["user"]["proxy"])')"
  for attempt in {1..15}; do
    if answer="$(curl -fsS --max-time 12 --proxy "$proxy" https://api.ipify.org 2>/dev/null)"; then
      log "Authenticated proxy check passed (exit IP: ${answer})"
      return
    fi
    sleep 2
  done
  journalctl -u naive-proxy -n 40 --no-pager >&2 || true
  die "Caddy is running, but an authenticated proxy request failed. Check DNS, provider firewall rules, and the log above."
}

verify_proxy
