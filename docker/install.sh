#!/usr/bin/env bash
if [ -z "${BASH_VERSION:-}" ]; then echo "Run with bash." >&2; exit 1; fi
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/lib/common.sh"
PORT="" HOST=127.0.0.1
while [[ $# -gt 0 ]]; do
  case "$1" in
    --port) [[ $# -ge 2 ]] || die "--port needs a value."; PORT="$2"; shift 2 ;;
    --host) [[ $# -ge 2 ]] || die "--host needs a value."; HOST="$2"; shift 2 ;;
    *) die "Unknown option: $1" ;;
  esac
done
require_linux_root
[[ "$HOST" == 127.0.0.1 || "$HOST" == 0.0.0.0 ]] || die "Panel host must be 127.0.0.1 or 0.0.0.0."
PORT="$(ask_port "Panel TCP port" 51821 "$PORT")"
[[ -x /usr/local/bin/caddy ]] || die "Install the NaiveProxy service before the panel."
if ! command -v docker >/dev/null 2>&1; then
  log "Installing Docker"
  command -v curl >/dev/null 2>&1 || install_packages curl ca-certificates
  curl -fsSL https://get.docker.com | sh
fi
if ! docker compose version >/dev/null 2>&1; then
  if [[ "$PKG" == apt ]]; then install_packages docker-compose-plugin; else install_packages docker-compose-plugin; fi
fi
systemctl enable --now docker 2>/dev/null || true
log "Building and starting the web panel"
CADDY_GID="$(getent group caddy | cut -d: -f3)"
[[ "$CADDY_GID" =~ ^[0-9]+$ ]] || die "The caddy group was not found."
NPQ_UI_PORT="$PORT" NPQ_UI_HOST="$HOST" NPQ_CADDY_GID="$CADDY_GID" docker compose -f "$ROOT/docker/docker-compose.yml" up -d --build --remove-orphans
for _ in {1..30}; do curl -fsS "http://127.0.0.1:${PORT}/api/health" >/dev/null && break; sleep 1; done
curl -fsS "http://127.0.0.1:${PORT}/api/health" >/dev/null || die "The panel did not start. Run docker compose logs for details."
if [[ "$HOST" == 0.0.0.0 ]]; then
  warn "The panel is publicly exposed over unencrypted HTTP. Restrict it in the provider firewall."
  open_firewall "$PORT" "NaiveProxy panel"
else
  log "Panel is bound to localhost. Use: ssh -L ${PORT}:127.0.0.1:${PORT} root@SERVER"
fi
log "Panel is ready on ${HOST}:${PORT}"
