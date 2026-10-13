#!/usr/bin/env bash

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  echo "Source this file from an installer." >&2
  exit 1
fi

log() { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m ! \033[0m %s\n' "$*" >&2; }
die() { printf '\033[1;31m x \033[0m %s\n' "$*" >&2; exit 1; }

require_linux_root() {
  [[ "$(uname -s)" == Linux ]] || die "This installer runs on Linux."
  [[ "${EUID}" -eq 0 ]] || die "Run this installer as root."
  [[ -r /etc/os-release ]] || die "Could not identify this Linux distribution."
  # shellcheck disable=SC1091
  source /etc/os-release
  case "${ID:-}:${ID_LIKE:-}" in
    ubuntu:*|debian:*|linuxmint:*|pop:*|elementary:*|zorin:*|*:debian*|*:ubuntu*) PKG=apt ;;
    fedora:*|rhel:*|centos:*|rocky:*|almalinux:*|ol:*|*:fedora*|*:rhel*) PKG=dnf ;;
    *) die "Unsupported distribution: ${PRETTY_NAME:-${ID:-unknown}}. Use Debian, Ubuntu, Fedora, Rocky, or AlmaLinux." ;;
  esac
  log "Detected ${PRETTY_NAME:-$ID}"
}

install_packages() {
  if [[ "$PKG" == apt ]]; then
    export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a
    apt-get update
    apt-get install -y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold "$@"
  else
    dnf install -y "$@"
  fi
}

domain_ok() {
  local value="${1,,}"
  [[ ${#value} -le 253 && "$value" == *.* && "$value" != .* && "$value" != *. ]] || return 1
  [[ "$value" =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$ ]] || return 1
  local label
  IFS=. read -ra labels <<<"$value"
  for label in "${labels[@]}"; do
    [[ -n "$label" && ${#label} -le 63 && "$label" != -* && "$label" != *- ]] || return 1
  done
}

ask_domain() {
  local preset="${1:-}" answer=""
  if [[ -n "$preset" ]]; then
    preset="${preset,,}"
    domain_ok "$preset" || die "Invalid domain: ${preset}"
    printf '%s\n' "$preset"
    return
  fi
  if ! { : </dev/tty; } 2>/dev/null || ! { : >/dev/tty; } 2>/dev/null; then
    die "A domain is required. Re-run with --domain proxy.example.com."
  fi
  printf 'Domain (required, for example proxy.example.com): ' >/dev/tty
  IFS= read -r answer </dev/tty || true
  answer="${answer//[[:space:]]/}"
  [[ -n "$answer" ]] || die "Domain was not provided. Installation stopped without changes."
  answer="${answer,,}"
  domain_ok "$answer" || die "Invalid domain: ${answer}"
  printf '%s\n' "$answer"
}

port_ok() { [[ "$1" =~ ^[0-9]{1,5}$ ]] && (( 10#$1 >= 1 && 10#$1 <= 65535 )); }

port_busy() {
  local port="$1"
  if [[ -r /var/lib/naive-proxy-quick/state.json ]] && command -v python3 >/dev/null 2>&1; then
    local owned
    owned="$(python3 -c 'import json,sys
try: print(json.load(open(sys.argv[1])).get("server",{}).get("port",""))
except Exception: pass' /var/lib/naive-proxy-quick/state.json 2>/dev/null || true)"
    if [[ "$owned" == "$port" ]] && command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet naive-proxy; then
      return 1
    fi
  fi
  if command -v docker >/dev/null 2>&1; then
    local container environment
    container="$(docker ps --filter 'label=com.docker.compose.project=naive-proxy-quick' --format '{{.ID}}' 2>/dev/null | head -1)"
    if [[ -n "$container" ]]; then
      environment="$(docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$container" 2>/dev/null || true)"
      [[ "$environment" == *$'\n'"PORT=${port}"$'\n'* || "$environment" == "PORT=${port}"$'\n'* ]] && return 1
    fi
  fi
  command -v ss >/dev/null 2>&1 || return 1
  [[ -n "$(ss -H -lnt "sport = :${port}" 2>/dev/null || true)" ]]
}

ask_port() {
  local label="$1" default="$2" preset="${3:-}" answer="" port=""
  if [[ -n "$preset" ]]; then
    port_ok "$preset" || die "${label} must be from 1 to 65535."
    if ! port_busy "$preset"; then printf '%s\n' "$preset"; return; fi
    warn "TCP port ${preset} is already in use."
  fi
  if ! { : </dev/tty; } 2>/dev/null || ! { : >/dev/tty; } 2>/dev/null; then
    port_busy "$default" && die "TCP port ${default} is already in use."
    printf '%s\n' "$default"
    return
  fi
  while true; do
    printf '%s [%s]: ' "$label" "$default" >/dev/tty
    IFS= read -r answer </dev/tty || die "No answer on the terminal."
    port="${answer:-$default}"
    if ! port_ok "$port"; then warn "Enter a port from 1 to 65535."; continue; fi
    if port_busy "$port"; then warn "TCP port ${port} is already in use."; continue; fi
    printf '%s\n' "$port"
    return
  done
}

ask_yes_no() {
  local label="$1" default="${2:-n}" answer="" hint='[y/N]'
  [[ "$default" == y ]] && hint='[Y/n]'
  if ! { : </dev/tty; } 2>/dev/null || ! { : >/dev/tty; } 2>/dev/null; then
    [[ "$default" == y ]] && printf 'yes\n' || printf 'no\n'
    return
  fi
  while true; do
    printf '%s %s: ' "$label" "$hint" >/dev/tty
    IFS= read -r answer </dev/tty || die "No answer on the terminal."
    answer="${answer,,}"
    [[ -n "$answer" ]] || answer="$default"
    case "$answer" in y|yes) printf 'yes\n'; return ;; n|no) printf 'no\n'; return ;; *) warn "Enter y or n." ;; esac
  done
}

open_firewall() {
  local port="$1" comment="${2:-NaiveProxy Quick}"
  if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    firewall-cmd --permanent --add-port="${port}/tcp"
    firewall-cmd --reload
  fi
  if command -v ufw >/dev/null 2>&1 && ufw status | grep -q 'Status: active'; then
    ufw allow "${port}/tcp" comment "$comment"
  fi
}
