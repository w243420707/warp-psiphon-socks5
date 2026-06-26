#!/usr/bin/env bash
set -Eeuo pipefail

# Standalone extractor for:
#   WARP-plus-Socks5 multi-region Psiphon proxy mode
# from https://github.com/yonggekkk/x-ui-yg/blob/main/install.sh
#
# Default:
#   - listens on 127.0.0.1:40000
#   - starts the Psiphon/WARP Socks5 proxy
#   - enables autostart with systemd when available, otherwise cron
#
# Examples:
#   bash warp_psiphon_socks5.sh
#   bash warp_psiphon_socks5.sh install JP 40000
#   COUNTRY=SG PORT=40000 bash warp_psiphon_socks5.sh install
#   bash warp_psiphon_socks5.sh status
#   bash warp_psiphon_socks5.sh stop
#   bash warp_psiphon_socks5.sh uninstall

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;36m'
PLAIN='\033[0m'

APP_NAME="warp-plus-psiphon"
BASE_DIR="/usr/local/${APP_NAME}"
BIN_PATH="${BASE_DIR}/xuiwpph"
RUNNER_PATH="${BASE_DIR}/run.sh"
ENV_PATH="/etc/${APP_NAME}.env"
SERVICE_PATH="/etc/systemd/system/${APP_NAME}.service"
PID_PATH="${BASE_DIR}/xuiwpphid.log"
LOG_PATH="${BASE_DIR}/xuiwpph.log"
RUNTIME_LOG_PATH="${BASE_DIR}/runtime.log"
ENDPOINT="162.159.192.1:2408"
DEFAULT_BIND="127.0.0.1"
DEFAULT_PORT="40000"
DEFAULT_RETRIES_PER_COUNTRY="3"
DEFAULT_PROXY_TEST_DELAY="20"
DEFAULT_PROXY_TEST_TIMEOUT="20"
COUNTRY_SOURCE_URL="https://raw.githubusercontent.com/bepass-org/warp-plus/master/README.md"

FALLBACK_COUNTRIES=(
  AT AU BE BG CA CH CZ DE DK EE ES FI FR GB HR HU IE IN IT JP LV NL NO PL PT RO RS SE SG SK US
)
SUPPORTED_COUNTRIES=("${FALLBACK_COUNTRIES[@]}")

COUNTRY_NAME_DATA='AT|Austria
AU|Australia
BE|Belgium
BG|Bulgaria
CA|Canada
CH|Switzerland
CZ|Czech Republic
DE|Germany
DK|Denmark
EE|Estonia
ES|Spain
FI|Finland
FR|France
GB|United Kingdom
HR|Croatia
HU|Hungary
IE|Ireland
IN|India
IT|Italy
JP|Japan
LV|Latvia
NL|Netherlands
NO|Norway
PL|Poland
PT|Portugal
RO|Romania
RS|Serbia
SE|Sweden
SG|Singapore
SK|Slovakia
US|United States'
COUNTRY_SOURCE="fallback"

info() { printf "${BLUE}%s${PLAIN}\n" "$*"; }
ok() { printf "${GREEN}%s${PLAIN}\n" "$*"; }
warn() { printf "${YELLOW}%s${PLAIN}\n" "$*"; }
err() { printf "${RED}%s${PLAIN}\n" "$*" >&2; }

usage() {
  cat <<EOF
Usage:
  bash $0 [install|start|restart|stop|status|uninstall] [COUNTRY] [PORT]

Default action is install.

Environment variables:
  COUNTRY   Psiphon region code. No default; interactive runs will ask.
  PORT      local Socks5 port, default ${DEFAULT_PORT}
  BIND      listen address, default ${DEFAULT_BIND}

Supported countries:
$(format_country_list)
EOF
}

need_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    err "Please run as root."
    exit 1
  fi
}

has_cmd() {
  command -v "$1" >/dev/null 2>&1
}

country_name() {
  local code="$1"
  local line
  while IFS= read -r line; do
    [[ "${line%%|*}" == "${code}" ]] && {
      printf '%s' "${line#*|}"
      return
    }
  done <<< "${COUNTRY_NAME_DATA}"
  printf 'Unknown'
}

format_country_list() {
  local code
  for code in "${SUPPORTED_COUNTRIES[@]}"; do
    printf '%s  %s\n' "${code}" "$(country_name "${code}")"
  done
}

fetch_supported_countries() {
  local readme countries

  readme="$(curl -fsSL --max-time 10 "${COUNTRY_SOURCE_URL}" 2>/dev/null || true)"
  [[ -n "${readme}" ]] || return 1

  countries="$(
    printf '%s\n' "${readme}" |
      sed -n 's/.*valid values: \[\([^]]*\)\].*/\1/p' |
      head -n 1 |
      tr ' ' '\n' |
      grep -E '^[A-Z]{2}$' |
      tr '\n' ' ' |
      sed 's/[[:space:]]*$//' || true
  )"

  [[ -n "${countries}" ]] || return 1
  printf '%s\n' "${countries}"
}

refresh_supported_countries() {
  local fetched

  fetched="$(fetch_supported_countries || true)"
  if [[ -n "${fetched}" ]]; then
    read -r -a SUPPORTED_COUNTRIES <<< "${fetched}"
    COUNTRY_SOURCE="remote"
  else
    SUPPORTED_COUNTRIES=("${FALLBACK_COUNTRIES[@]}")
    COUNTRY_SOURCE="fallback"
    warn "Could not fetch latest Psiphon country list; using built-in fallback list."
  fi
}

install_deps() {
  local missing_cmds=()
  local packages=()
  local pkg=""
  local cmd
  local os_family=""
  local pkg_manager=""
  local arch

  arch="$(detect_arch)"
  info "Detected architecture: ${arch}"

  for cmd in curl awk sed grep tr nohup setsid ss pgrep pkill crontab; do
    has_cmd "${cmd}" || missing_cmds+=("${cmd}")
  done

  if ((${#missing_cmds[@]} == 0)); then
    ok "Required runtime dependencies are already installed."
    return
  fi

  if has_cmd apt-get; then
    pkg_manager="apt-get"
    os_family="debian"
  elif has_cmd dnf; then
    pkg_manager="dnf"
    os_family="rhel"
  elif has_cmd yum; then
    pkg_manager="yum"
    os_family="rhel"
  elif has_cmd apk; then
    pkg_manager="apk"
    os_family="alpine"
  else
    err "No supported package manager found. Missing commands: ${missing_cmds[*]}"
    exit 1
  fi

  info "Detected package manager: ${pkg_manager}"
  warn "Missing commands: ${missing_cmds[*]}"

  add_package() {
    local candidate="$1"
    local existing
    for existing in "${packages[@]:-}"; do
      [[ "${existing}" == "${candidate}" ]] && return
    done
    packages+=("${candidate}")
  }

  package_for_command() {
    local command_name="$1"
    case "${os_family}:${command_name}" in
      debian:curl) echo "curl ca-certificates" ;;
      debian:ss) echo "iproute2" ;;
      debian:pgrep | debian:pkill) echo "procps" ;;
      debian:crontab) echo "cron" ;;
      debian:setsid) echo "util-linux" ;;
      debian:nohup) echo "coreutils" ;;
      debian:awk) echo "gawk" ;;
      debian:sed) echo "sed" ;;
      debian:grep) echo "grep" ;;
      debian:tr) echo "coreutils" ;;

      rhel:curl) echo "curl ca-certificates" ;;
      rhel:ss) echo "iproute" ;;
      rhel:pgrep | rhel:pkill) echo "procps-ng" ;;
      rhel:crontab) echo "cronie" ;;
      rhel:setsid) echo "util-linux" ;;
      rhel:nohup) echo "coreutils" ;;
      rhel:awk) echo "gawk" ;;
      rhel:sed) echo "sed" ;;
      rhel:grep) echo "grep" ;;
      rhel:tr) echo "coreutils" ;;

      alpine:curl) echo "curl ca-certificates" ;;
      alpine:ss) echo "iproute2" ;;
      alpine:pgrep | alpine:pkill) echo "procps" ;;
      alpine:crontab) echo "dcron" ;;
      alpine:setsid) echo "util-linux" ;;
      alpine:nohup) echo "coreutils" ;;
      alpine:awk) echo "gawk" ;;
      alpine:sed) echo "sed" ;;
      alpine:grep) echo "grep" ;;
      alpine:tr) echo "coreutils" ;;
    esac
  }

  for cmd in "${missing_cmds[@]}"; do
    for pkg in $(package_for_command "${cmd}"); do
      [[ -n "${pkg}" ]] && add_package "${pkg}"
    done
  done

  if ((${#packages[@]} == 0)); then
    err "Could not map missing commands to packages: ${missing_cmds[*]}"
    exit 1
  fi

  warn "Installing missing packages only: ${packages[*]}"
  case "${pkg_manager}" in
    apt-get)
      apt-get update -y
      DEBIAN_FRONTEND=noninteractive apt-get install -y "${packages[@]}"
      ;;
    dnf)
      dnf install -y "${packages[@]}"
      ;;
    yum)
      yum install -y "${packages[@]}"
      ;;
    apk)
      apk update
      apk add "${packages[@]}"
      ;;
  esac

  missing_cmds=()
  for cmd in curl awk sed grep tr nohup setsid ss pgrep pkill crontab; do
    has_cmd "${cmd}" || missing_cmds+=("${cmd}")
  done

  if ((${#missing_cmds[@]} > 0)); then
    err "Dependency installation finished, but these commands are still missing: ${missing_cmds[*]}"
    exit 1
  fi

  ok "Dependencies are ready."
}

detect_arch() {
  case "$(uname -m)" in
    x86_64 | amd64)
      echo "amd64"
      ;;
    aarch64 | arm64)
      echo "arm64"
      ;;
    *)
      err "Unsupported CPU architecture: $(uname -m). Only amd64 and arm64 are supported."
      exit 1
      ;;
  esac
}

detect_ip_version() {
  local v4
  v4="$(curl -s4m5 https://icanhazip.com -k || true)"
  if [[ -n "${v4}" ]]; then
    echo "4"
  else
    warn "IPv4 was not detected, falling back to IPv6 mode."
    echo "6"
  fi
}

is_supported_country() {
  local country="$1"
  local item
  for item in "${SUPPORTED_COUNTRIES[@]}"; do
    [[ "${item}" == "${country}" ]] && return 0
  done
  return 1
}

normalize_country() {
  local country="${1:-}"
  country="$(printf '%s' "${country}" | tr '[:lower:]' '[:upper:]')"
  if [[ -z "${country}" ]]; then
    err "Country code is required."
    usage
    exit 1
  fi
  if ! is_supported_country "${country}"; then
    err "Unsupported country code: ${country}"
    usage
    exit 1
  fi
  echo "${country}"
}

select_country() {
  local country

  {
    info "Psiphon country list source: ${COUNTRY_SOURCE}"
    format_country_list
  } >&2
  while true; do
    read -r -p "Choose country code (two uppercase letters, e.g. JP/SG/US): " country
    country="$(printf '%s' "${country}" | tr '[:lower:]' '[:upper:]')"
    if [[ -z "${country}" ]]; then
      warn "Country code cannot be empty." >&2
      continue
    fi
    if is_supported_country "${country}"; then
      echo "${country}"
      return
    fi
    warn "Unsupported country code: ${country}" >&2
  done
}

normalize_port() {
  local port="${1:-}"
  if [[ -z "${port}" ]]; then
    port="${DEFAULT_PORT}"
  fi
  if ! [[ "${port}" =~ ^[0-9]+$ ]] || ((port < 1 || port > 65535)); then
    err "Invalid port: ${port}"
    exit 1
  fi
  echo "${port}"
}

port_in_use() {
  local port="$1"
  ss -H -tunlp 2>/dev/null | awk '{print $5}' | sed 's/.*://g' | grep -qx "${port}"
}

stop_process() {
  if has_cmd systemctl && [[ -f "${SERVICE_PATH}" ]]; then
    systemctl stop "${APP_NAME}" >/dev/null 2>&1 || true
  fi

  if [[ -s "${PID_PATH}" ]]; then
    local pid
    pid="$(cat "${PID_PATH}" 2>/dev/null || true)"
    if [[ -n "${pid}" ]] && kill -0 "${pid}" >/dev/null 2>&1; then
      kill -15 "${pid}" >/dev/null 2>&1 || true
      sleep 2
    fi
  fi

  pkill -f "${BIN_PATH}" >/dev/null 2>&1 || true
  rm -f "${PID_PATH}"
}

download_binary() {
  local arch url tmp
  arch="$(detect_arch)"
  url="https://raw.githubusercontent.com/yonggekkk/x-ui-yg/main/xuiwpph_${arch}"
  tmp="${BIN_PATH}.download.$$"

  mkdir -p "${BASE_DIR}"
  stop_process
  rm -f "${tmp}"
  info "Downloading xuiwpph_${arch} ..."
  if ! curl -fL --retry 3 -o "${tmp}" "${url}"; then
    warn "Normal download failed, retrying with --insecure."
    curl -fL --retry 3 --insecure -o "${tmp}" "${url}" || {
      rm -f "${tmp}"
      return 1
    }
  fi
  chmod +x "${tmp}"
  mv -f "${tmp}" "${BIN_PATH}"
}

write_config() {
  local country="$1"
  local port="$2"
  local bind_addr="$3"
  local ip_version="$4"

  cat > "${ENV_PATH}" <<EOF
COUNTRY=${country}
PORT=${port}
BIND=${bind_addr}
IP_VERSION=${ip_version}
ENDPOINT=${ENDPOINT}
EOF

  cat > "${LOG_PATH}" <<EOF
${BIN_PATH} -b ${bind_addr}:${port} --cfon --country ${country} -${ip_version} --endpoint ${ENDPOINT}
EOF
}

write_runner() {
  cat > "${RUNNER_PATH}" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

APP_NAME="warp-plus-psiphon"
BASE_DIR="/usr/local/${APP_NAME}"
BIN_PATH="${BASE_DIR}/xuiwpph"
ENV_PATH="/etc/${APP_NAME}.env"
PID_PATH="${BASE_DIR}/xuiwpphid.log"

source "${ENV_PATH}"

echo "$$" > "${PID_PATH}"
exec "${BIN_PATH}" \
  -b "${BIND}:${PORT}" \
  --cfon \
  --country "${COUNTRY}" \
  "-${IP_VERSION}" \
  --endpoint "${ENDPOINT}"
EOF
  chmod +x "${RUNNER_PATH}"
}

setup_autostart() {
  if has_cmd systemctl && [[ -d /run/systemd/system ]]; then
    cat > "${SERVICE_PATH}" <<EOF
[Unit]
Description=WARP-plus Socks5 multi-region Psiphon proxy
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${RUNNER_PATH}
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable "${APP_NAME}" >/dev/null 2>&1
  else
    warn "systemd is not available; using crontab for boot startup."
    crontab -l 2>/dev/null > /tmp/${APP_NAME}.cron || true
    sed -i "/${APP_NAME}/d" /tmp/${APP_NAME}.cron
    printf '@reboot sleep 10 && /bin/bash -c "nohup setsid %s >> %s 2>&1 & echo \\$! > %s" # %s\n' \
      "${RUNNER_PATH}" "${RUNTIME_LOG_PATH}" "${PID_PATH}" "${APP_NAME}" >> /tmp/${APP_NAME}.cron
    crontab /tmp/${APP_NAME}.cron
    rm -f /tmp/${APP_NAME}.cron
  fi
}

start_proxy() {
  local port="$1"

  stop_process
  if port_in_use "${port}"; then
    err "Port ${port} is already in use. Choose another port."
    exit 1
  fi

  if has_cmd systemctl && [[ -f "${SERVICE_PATH}" ]] && [[ -d /run/systemd/system ]]; then
    systemctl restart "${APP_NAME}"
  else
    nohup setsid "${RUNNER_PATH}" >> "${RUNTIME_LOG_PATH}" 2>&1 &
    echo "$!" > "${PID_PATH}"
  fi
}

test_proxy() {
  local port="$1"
  local result
  local delay="${PROXY_TEST_DELAY:-${DEFAULT_PROXY_TEST_DELAY}}"
  local timeout="${PROXY_TEST_TIMEOUT:-${DEFAULT_PROXY_TEST_TIMEOUT}}"

  info "Requesting IP through Socks5 after ${delay}s startup wait ..."
  sleep "${delay}"
  result="$(curl -s --max-time "${timeout}" --socks5-hostname "127.0.0.1:${port}" https://icanhazip.com || true)"
  if [[ -z "${result}" ]]; then
    return 1
  fi

  ok "WARP-plus-Socks5 is ready."
  ok "Socks5: 127.0.0.1:${port}"
  ok "Proxy IP: ${result}"
}

retry_selected_country() {
  local country="$1"
  local port="$2"
  local bind_addr="$3"
  local ip_version="$4"
  local retries="${RETRIES_PER_COUNTRY:-${DEFAULT_RETRIES_PER_COUNTRY}}"
  local attempt

  if ! [[ "${retries}" =~ ^[1-9][0-9]*$ ]]; then
    warn "Invalid RETRIES_PER_COUNTRY=${retries}; using ${DEFAULT_RETRIES_PER_COUNTRY}."
    retries="${DEFAULT_RETRIES_PER_COUNTRY}"
  fi

  for ((attempt = 1; attempt <= retries; attempt++)); do
    info "Trying Psiphon country ${country} (${attempt}/${retries}) ..."
    write_config "${country}" "${port}" "${bind_addr}" "${ip_version}"
    start_proxy "${port}"

    if test_proxy "${port}"; then
      ok "Selected country is working: ${country}"
      return
    fi

    warn "Country ${country} failed on attempt ${attempt}/${retries}."
    stop_process
    if ((attempt < retries)); then
      sleep 3
    fi
  done

  err "WARP-plus-Socks5 IP check failed after ${retries} attempts for country ${country}."
  err "The service has been stopped. Try the same country later, or rerun and choose another country manually."
  exit 1
}

install_or_restart() {
  local country="${1:-${COUNTRY:-}}"
  local port="${2:-${PORT:-}}"
  local bind_arg="${BIND:-}"
  local bind_addr
  local configured_country=""
  local configured_port=""
  local configured_bind=""
  local ip_version

  if [[ -f "${ENV_PATH}" ]]; then
    # shellcheck disable=SC1090
    source "${ENV_PATH}"
    configured_country="${COUNTRY:-}"
    configured_port="${PORT:-}"
    configured_bind="${BIND:-}"
  fi

  if [[ -z "${country}" ]]; then
    if [[ -t 0 ]]; then
      country="$(select_country)"
    else
      country="${configured_country}"
    fi
  fi

  port="${port:-${configured_port:-}}"
  bind_addr="${bind_arg:-${configured_bind:-${DEFAULT_BIND}}}"

  country="$(normalize_country "${country}")"
  port="$(normalize_port "${port}")"

  if [[ "${bind_addr}" != "${DEFAULT_BIND}" ]]; then
    warn "BIND is ${bind_addr}. Make sure your firewall does not expose an open Socks5 proxy unintentionally."
  fi

  download_binary
  ip_version="$(detect_ip_version)"
  write_runner
  setup_autostart
  retry_selected_country "${country}" "${port}" "${bind_addr}" "${ip_version}"
}

status() {
  local country="" port="" bind_addr="" ip_version="" pid=""

  if [[ -f "${ENV_PATH}" ]]; then
    # shellcheck disable=SC1090
    source "${ENV_PATH}"
    country="${COUNTRY:-}"
    port="${PORT:-}"
    bind_addr="${BIND:-}"
    ip_version="${IP_VERSION:-}"
  fi

  if [[ -s "${PID_PATH}" ]]; then
    pid="$(cat "${PID_PATH}" 2>/dev/null || true)"
  fi

  echo "Service: ${APP_NAME}"
  echo "Config : ${ENV_PATH}"
  echo "Binary : ${BIN_PATH}"
  [[ -n "${country}" ]] && echo "Country: ${country}"
  [[ -n "${port}" ]] && echo "Socks5 : ${bind_addr}:${port}"
  [[ -n "${ip_version}" ]] && echo "IP mode: IPv${ip_version}"

  if [[ -n "${pid}" ]] && kill -0 "${pid}" >/dev/null 2>&1; then
    ok "Status : running, pid ${pid}"
  elif pgrep -f "${BIN_PATH}" >/dev/null 2>&1; then
    ok "Status : running"
  else
    warn "Status : stopped"
  fi

  if [[ -n "${port}" ]]; then
    local result
    result="$(curl -s --max-time 10 --socks5-hostname "127.0.0.1:${port}" https://icanhazip.com || true)"
    [[ -n "${result}" ]] && echo "Proxy IP: ${result}"
  fi
}

stop_proxy() {
  stop_process
  ok "Stopped ${APP_NAME}."
}

uninstall_proxy() {
  stop_process

  if has_cmd systemctl && [[ -f "${SERVICE_PATH}" ]]; then
    systemctl disable "${APP_NAME}" >/dev/null 2>&1 || true
    rm -f "${SERVICE_PATH}"
    systemctl daemon-reload >/dev/null 2>&1 || true
    systemctl reset-failed >/dev/null 2>&1 || true
  fi

  crontab -l 2>/dev/null > /tmp/${APP_NAME}.cron || true
  sed -i "/${APP_NAME}/d" /tmp/${APP_NAME}.cron
  crontab /tmp/${APP_NAME}.cron >/dev/null 2>&1 || true
  rm -f /tmp/${APP_NAME}.cron

  rm -rf "${BASE_DIR}" "${ENV_PATH}"
  ok "Uninstalled ${APP_NAME}."
}

main() {
  local action="${1:-install}"
  shift || true

  case "${action}" in
    install | start | restart)
      need_root
      install_deps
      refresh_supported_countries
      install_or_restart "${1:-}" "${2:-}"
      ;;
    stop)
      need_root
      stop_proxy
      ;;
    status)
      status
      ;;
    uninstall | remove)
      need_root
      uninstall_proxy
      ;;
    help | -h | --help)
      refresh_supported_countries
      usage
      ;;
    *)
      err "Unknown action: ${action}"
      usage
      exit 1
      ;;
  esac
}

main "$@"
