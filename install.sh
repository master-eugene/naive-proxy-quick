#!/usr/bin/env bash
# One-line installer:
# bash <(curl -fsSL https://raw.githubusercontent.com/master-eugene/naive-proxy-quick/master/install.sh)

if [ -z "${BASH_VERSION:-}" ]; then echo "Run this script with bash." >&2; exit 1; fi
set -euo pipefail

REPO_URL=https://github.com/master-eugene/naive-proxy-quick.git
RAW_URL=https://raw.githubusercontent.com/master-eugene/naive-proxy-quick/master/install.sh
BRANCH=master
INSTALL_DIR=/opt/naive-proxy-quick

log() { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m x \033[0m %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<EOF
Usage:
  bash <(curl -fsSL ${RAW_URL})
  sudo bash install.sh [--domain proxy.example.com] [--proxy-port 443]
                       [--panel yes|no] [--panel-port 51821]
                       [--panel-access local|public] [--bbr yes|no]
                       [--decoy-url https://example.com]

The domain is mandatory. An empty answer stops before packages or configuration
are changed. The installer then asks for the proxy port, whether to install the
web panel, and (when selected) the panel port.
EOF
}

is_fd() { case "$1" in /dev/fd/*|/proc/*/fd/*) return 0 ;; *) return 1 ;; esac; }
script_dir() { local src="${BASH_SOURCE[0]:-}"; [[ -n "$src" && -f "$src" ]] || return 1; is_fd "$src" && return 1; (cd "$(dirname "$src")" && pwd); }
in_checkout() { [[ -f "$1/console/install.sh" && -f "$1/docker/install.sh" && -f "$1/lib/common.sh" && -f "$1/cover/index.html" ]]; }

DOMAIN="" PROXY_PORT="" PANEL="" PANEL_PORT="" PANEL_ACCESS="" BBR="" DECOY_URL="" DECOY_SET=0
parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --domain) [[ $# -ge 2 ]] || die "--domain needs a value."; DOMAIN="$2"; shift 2 ;;
      --domain=*) DOMAIN="${1#*=}"; shift ;;
      --proxy-port) [[ $# -ge 2 ]] || die "--proxy-port needs a value."; PROXY_PORT="$2"; shift 2 ;;
      --proxy-port=*) PROXY_PORT="${1#*=}"; shift ;;
      --panel) [[ $# -ge 2 ]] || die "--panel needs yes or no."; PANEL="${2,,}"; shift 2 ;;
      --panel=*) PANEL="${1#*=}"; PANEL="${PANEL,,}"; shift ;;
      --panel-port) [[ $# -ge 2 ]] || die "--panel-port needs a value."; PANEL_PORT="$2"; shift 2 ;;
      --panel-port=*) PANEL_PORT="${1#*=}"; shift ;;
      --panel-access) [[ $# -ge 2 ]] || die "--panel-access needs local or public."; PANEL_ACCESS="${2,,}"; shift 2 ;;
      --panel-access=*) PANEL_ACCESS="${1#*=}"; PANEL_ACCESS="${PANEL_ACCESS,,}"; shift ;;
      --bbr) [[ $# -ge 2 ]] || die "--bbr needs yes or no."; BBR="${2,,}"; shift 2 ;;
      --bbr=*) BBR="${1#*=}"; BBR="${BBR,,}"; shift ;;
      --decoy-url) [[ $# -ge 2 ]] || die "--decoy-url needs a value."; DECOY_URL="$2"; DECOY_SET=1; shift 2 ;;
      --decoy-url=*) DECOY_URL="${1#*=}"; DECOY_SET=1; shift ;;
      -h|--help|help) usage; exit 0 ;;
      *) die "Unknown option: $1" ;;
    esac
  done
  case "$PANEL" in ""|yes|y|no|n) ;; *) die "--panel must be yes or no." ;; esac
  case "$PANEL_ACCESS" in ""|local|public) ;; *) die "--panel-access must be local or public." ;; esac
  case "$BBR" in ""|yes|y|no|n) ;; *) die "--bbr must be yes or no." ;; esac
  validate_decoy_arg
}

validate_decoy_arg() {
  if [[ "$DECOY_SET" -eq 1 && -n "$DECOY_URL" && "${DECOY_URL,,}" != none && "$DECOY_URL" != http://* && "$DECOY_URL" != https://* ]]; then
    die "--decoy-url must start with http:// or https://, or be 'none'."
  fi
}

minimal_domain_ok() {
  [[ -n "$1" && "$1" == *.* && "$1" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]]
}

collect_domain_before_changes() {
  if [[ -n "$DOMAIN" ]]; then
    minimal_domain_ok "$DOMAIN" || die "Invalid domain: ${DOMAIN}"
    DOMAIN="${DOMAIN,,}"
    return
  fi
  if ! { : </dev/tty; } 2>/dev/null || ! { : >/dev/tty; } 2>/dev/null; then
    die "A domain is required. Re-run with --domain proxy.example.com."
  fi
  printf 'Domain (required, for example proxy.example.com): ' >/dev/tty
  IFS= read -r DOMAIN </dev/tty || true
  DOMAIN="${DOMAIN//[[:space:]]/}"
  [[ -n "$DOMAIN" ]] || die "Domain was not provided. Installation stopped without changes."
  minimal_domain_ok "$DOMAIN" || die "Invalid domain: ${DOMAIN}"
  DOMAIN="${DOMAIN,,}"
}

become_root() {
  [[ "$EUID" -eq 0 ]] && return
  command -v sudo >/dev/null 2>&1 || die "Run this installer as root."
  local args=(--domain "$DOMAIN")
  [[ -z "$PROXY_PORT" ]] || args+=(--proxy-port "$PROXY_PORT")
  [[ -z "$PANEL" ]] || args+=(--panel "$PANEL")
  [[ -z "$PANEL_PORT" ]] || args+=(--panel-port "$PANEL_PORT")
  [[ -z "$PANEL_ACCESS" ]] || args+=(--panel-access "$PANEL_ACCESS")
  [[ -z "$BBR" ]] || args+=(--bbr "$BBR")
  [[ "$DECOY_SET" -eq 0 ]] || args+=(--decoy-url "$DECOY_URL")
  local src="${BASH_SOURCE[0]:-}"
  if [[ -n "$src" && -f "$src" ]] && ! is_fd "$src"; then exec sudo bash "$src" "${args[@]}"; fi
  command -v curl >/dev/null 2>&1 || die "Install curl or run as root."
  exec sudo bash -c "$(curl -fsSL "$RAW_URL")" bash "${args[@]}"
}

sync_checkout() {
  if ! command -v git >/dev/null 2>&1; then
    if command -v apt-get >/dev/null 2>&1; then apt-get update; apt-get install -y git ca-certificates;
    elif command -v dnf >/dev/null 2>&1; then dnf install -y git ca-certificates;
    else die "Install git and run this installer again."; fi
  fi
  export GIT_TERMINAL_PROMPT=0
  if [[ -d "$INSTALL_DIR/.git" ]]; then
    log "Updating ${INSTALL_DIR}"
    git -C "$INSTALL_DIR" remote set-url origin "$REPO_URL"
    git -C "$INSTALL_DIR" fetch --depth 1 origin "$BRANCH"
    git -C "$INSTALL_DIR" reset --hard FETCH_HEAD
  elif [[ -e "$INSTALL_DIR" && -n "$(ls -A "$INSTALL_DIR" 2>/dev/null || true)" ]]; then
    die "${INSTALL_DIR} exists and is not this project's Git checkout."
  else
    log "Downloading NaiveProxy Quick"
    mkdir -p "$(dirname "$INSTALL_DIR")"
    git clone --depth 1 --branch "$BRANCH" "$REPO_URL" "$INSTALL_DIR"
  fi
}

install_from() {
  local root="$1"
  # shellcheck disable=SC1091
  source "$root/lib/common.sh"
  require_linux_root
  DOMAIN="$(ask_domain "$DOMAIN")"
  PROXY_PORT="$(ask_port "NaiveProxy HTTPS port" 443 "$PROXY_PORT")"
  if [[ "$DECOY_SET" -eq 0 ]] && { : </dev/tty; } 2>/dev/null && { : >/dev/tty; } 2>/dev/null; then
    printf 'Camouflage URL (optional; Enter uses the local cover page): ' >/dev/tty
    IFS= read -r DECOY_URL </dev/tty || true
    DECOY_SET=1
    validate_decoy_arg
  fi
  if [[ -z "$BBR" ]]; then BBR="$(ask_yes_no "Enable BBR congestion control?" n)"; fi
  case "$BBR" in y|yes) BBR=yes ;; *) BBR=no ;; esac
  if [[ -z "$PANEL" ]]; then PANEL="$(ask_yes_no "Install the web panel?" n)"; fi
  case "$PANEL" in y|yes) PANEL=yes ;; *) PANEL=no ;; esac
  if [[ "$PANEL" == yes ]]; then
    PANEL_PORT="$(ask_port "Panel TCP port" 51821 "$PANEL_PORT")"
    if [[ -z "$PANEL_ACCESS" ]]; then
      if [[ "$(ask_yes_no "Expose the panel publicly over unencrypted HTTP?" n)" == yes ]]; then PANEL_ACCESS=public; else PANEL_ACCESS=local; fi
    fi
  fi
  console_args=(--domain "$DOMAIN" --port "$PROXY_PORT")
  [[ "$BBR" == yes ]] && console_args+=(--enable-bbr)
  if [[ "$DECOY_SET" -eq 1 ]]; then
    if [[ -n "$DECOY_URL" ]]; then console_args+=(--decoy-url "$DECOY_URL"); else console_args+=(--decoy-url none); fi
  fi
  bash "$root/console/install.sh" "${console_args[@]}"
  if [[ "$PANEL" == yes ]]; then
    panel_host=127.0.0.1
    [[ "$PANEL_ACCESS" == public ]] && panel_host=0.0.0.0
    bash "$root/docker/install.sh" --port "$PANEL_PORT" --host "$panel_host"
  fi
  local first
  first="$('/usr/local/bin/npq' --json user list | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["users"][0]["id"])')"
  cat <<EOF

NaiveProxy Quick is installed.

  Menu       sudo npq
  Proxy      ${DOMAIN}:${PROXY_PORT}
EOF
  if [[ "$PANEL" == yes && "$PANEL_ACCESS" == public ]]; then
    printf '  Panel      http://%s:%s (unencrypted public access)\n' "$DOMAIN" "$PANEL_PORT"
  elif [[ "$PANEL" == yes ]]; then
    printf '  Panel      http://127.0.0.1:%s through an SSH tunnel\n' "$PANEL_PORT"
    printf '  Tunnel     ssh -L %s:127.0.0.1:%s root@%s\n' "$PANEL_PORT" "$PANEL_PORT" "$DOMAIN"
  fi
  printf '\nFirst user link:\n'
  '/usr/local/bin/npq' --json user show --id "$first" | python3 -c 'import json,sys; print(json.load(sys.stdin)["user"]["link"])'
  printf '\n'
}

main() {
  parse_args "$@"
  collect_domain_before_changes
  become_root
  local root=""
  root="$(script_dir || true)"
  if in_checkout "$root"; then install_from "$root"; return; fi
  sync_checkout
  local args=(--domain "$DOMAIN")
  [[ -z "$PROXY_PORT" ]] || args+=(--proxy-port "$PROXY_PORT")
  [[ -z "$PANEL" ]] || args+=(--panel "$PANEL")
  [[ -z "$PANEL_PORT" ]] || args+=(--panel-port "$PANEL_PORT")
  [[ -z "$PANEL_ACCESS" ]] || args+=(--panel-access "$PANEL_ACCESS")
  [[ -z "$BBR" ]] || args+=(--bbr "$BBR")
  [[ "$DECOY_SET" -eq 0 ]] || args+=(--decoy-url "$DECOY_URL")
  exec bash "$INSTALL_DIR/install.sh" "${args[@]}"
}

main "$@"
