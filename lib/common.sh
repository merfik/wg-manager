# shellcheck shell=bash
# shellcheck disable=SC2034
set -euo pipefail

readonly PROGRAM=${0##*/}
readonly STATE_ROOT=${WG_MANAGER_STATE_ROOT:-/var/lib/wg-manager}
readonly ETC_ROOT=${WG_MANAGER_ETC_ROOT:-/etc/wireguard}
readonly UNIT_DIR=${WG_MANAGER_UNIT_DIR:-/etc/systemd/system}
readonly OPENRC_CONF_DIR=${WG_MANAGER_OPENRC_CONF_DIR:-/etc/conf.d}
readonly OPENRC_UNIT_DIR=${WG_MANAGER_OPENRC_UNIT_DIR:-/etc/init.d}
readonly SYSCTL_DIR=${WG_MANAGER_SYSCTL_DIR:-/etc/sysctl.d}

MODE=""
IFACE="wg0"
SUBNET="10.7.0.0/24"
IPV6=""
PORT="51820"
ENDPOINT=""
DNS="system"
MTU="1420"
KEEPALIVE="25"
PSK="0"
YES="0"
DRY_RUN="0"
LOG_FILE=""
COMMAND=""
ARGS=()
CLIENT=""
QR=0
SPLIT_TUNNEL=0
ROUTES=""
MODE_ARG=""
INSTALL_SUCCEEDED=0
UNINSTALL_SUCCEEDED=0

log() {
  local level=$1
  shift
  printf '%s [%s] %s\n' "$(date '+%Y-%m-%dT%H:%M:%SZ')" "$level" "$*" >&2
  if [[ -n "$LOG_FILE" ]]; then
    printf '%s [%s] %s\n' "$(date '+%Y-%m-%dT%H:%M:%SZ')" "$level" "$*" >>"$LOG_FILE"
  fi
}
die() {
  log ERROR "$*"
  exit 1
}
usage() {
  cat <<'EOF'
Usage: wg-manager [--help] [--prepare] [--prepare-install]

Run without arguments to open the interactive WireGuard installer and manager.

Options:
  --help             Show this help and exit.
  --prepare          Check system requirements and show missing packages (no root required).
  --prepare-install  Check requirements and install missing required packages (requires root).
EOF
}
require_root() {
  (( EUID == 0 )) || die "Root access is required. Re-run this command with sudo."
}
command_available() {
  command -v "$1" >/dev/null 2>&1
}
validate_iface() {
  if [[ ! $IFACE =~ ^[A-Za-z][A-Za-z0-9_.-]{0,14}$ ]]; then
    log ERROR "Invalid interface name '$IFACE'. Use 1-15 characters beginning with a letter; letters, digits, '_', '.', and '-' are allowed."
    return 1
  fi
}
validate_port() {
  if [[ ! $PORT =~ ^[0-9]+$ ]] || (( PORT < 1 || PORT > 65535 )); then
    log ERROR "Invalid listen port '$PORT'. Choose a port from 1 to 65535."
    return 1
  fi
}
validate_mtu() {
  if [[ ! $MTU =~ ^[0-9]+$ ]] || (( MTU < 1280 || MTU > 1500)); then
    log ERROR "Invalid MTU '$MTU'. Choose a value from 1280 to 1500."
    return 1
  fi
}
validate_keepalive() {
  if [[ ! $KEEPALIVE =~ ^[0-9]+$ ]] || (( KEEPALIVE < 0 || KEEPALIVE > 86400)); then
    log ERROR "Invalid keepalive '$KEEPALIVE'. Choose 0 to disable or a value from 1 to 86400 seconds."
    return 1
  fi
}
validate_cidr() {
  local cidr=$1
  if [[ ! $cidr =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/([0-9]|[12][0-9]|3[0-2])$ ]]; then
    log ERROR "Invalid CIDR '$cidr'. Use IPv4 notation such as 10.7.0.0/24."
    return 1
  fi
  local ip=${cidr%/*} prefix=${cidr#*/}
  local -a octets
  IFS=. read -r -a octets <<<"$ip"
  local octet
  for octet in "${octets[@]}"; do
    if (( octet > 255 )); then
      log ERROR "Invalid CIDR '$cidr'. An IPv4 octet must be from 0 to 255."
      return 1
    fi
  done
  if (( prefix < 0 || prefix > 32 )); then
    log ERROR "Invalid CIDR '$cidr'. Prefix length must be 0-32."
    return 1
  fi
}
validate_ipv6() {
  [[ -n $IPV6 ]] || return 0
  if ! python3 - "$IPV6" <<'PY' >/dev/null 2>&1
import ipaddress, sys
network = ipaddress.IPv6Network(sys.argv[1], strict=False)
if not network.is_private:
    raise SystemExit(1)
PY
  then
    log ERROR "Invalid IPv6 ULA CIDR '$IPV6'. Use notation such as fd00:7::/64."
    return 1
  fi
}
validate_endpoint() {
  [[ -n $ENDPOINT ]] || return 0
  if [[ $ENDPOINT =~ ^[0-9.]+$ ]]; then
    if ! python3 - "$ENDPOINT" <<'PY' >/dev/null 2>&1
import ipaddress, sys
ipaddress.IPv4Address(sys.argv[1])
PY
    then
      log ERROR "Invalid endpoint IP '$ENDPOINT'."
      return 1
    fi
  else
    if [[ ! $ENDPOINT =~ ^([A-Za-z0-9]|[A-Za-z0-9-]{1,63})(\.([A-Za-z0-9]|[A-Za-z0-9-]{1,63}))*$ ]]; then
      log ERROR "Invalid endpoint hostname '$ENDPOINT'. Use a valid DNS hostname or IP address."
      return 1
    fi
  fi
}
validate_dns() {
  case "$DNS" in
    system|cloudflare|google|quad9|opendns) return 0 ;;
  esac
  if [[ ! $DNS =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}(,[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3})?$ ]]; then
    log ERROR "Invalid DNS '$DNS'. Use system, cloudflare, google, quad9, opendns, or 1-2 comma-separated IPv4 addresses."
    return 1
  fi
  local address
  local -a addresses
  IFS=, read -r -a addresses <<<"$DNS"
  for address in "${addresses[@]}"; do
    if ! python3 - "$address" <<'PY' >/dev/null 2>&1
import ipaddress, sys
ipaddress.IPv4Address(sys.argv[1])
PY
    then
      log ERROR "Invalid DNS address '$address'."
      return 1
    fi
  done
}
confirm() {
  local prompt=$1
  [[ $YES == 1 ]] && return 0
  read -r -p "$prompt [y/N] " reply
  [[ ${reply,,} == y || ${reply,,} == yes ]]
}
check_system_requirements() {
  local uid=${1:-$EUID}
  local command_name
  local -a missing=()
  require_root "$uid"
  distro_detect
  for command_name in awk cat chmod date find getent grep head install \
    ip mkdir paste python3 rm sed ss sysctl tar wg wg-quick; do
    command_available "$command_name" || missing+=("$command_name")
  done
  if [[ $SERVICE_BACKEND == none ]]; then
    missing+=("systemd or OpenRC service manager")
  fi
  if ((${#missing[@]} > 0)); then
    log ERROR "Missing required system commands or services: ${missing[*]}. Install the corresponding packages (see README.md), then run wg-manager again."
    return 1
  fi
  if [[ $(detect_firewall) == none ]]; then
    log WARN "No supported firewall backend is active or installed. Install and configure UFW, firewalld, or iptables before installing an interface."
  fi
}
distro_detect() {
  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    DISTRO=${ID:-unknown}
  else
    DISTRO=unknown
  fi
  SERVICE_BACKEND=none
  if command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; then
    SERVICE_BACKEND=systemd
  elif command -v rc-service >/dev/null 2>&1; then
    SERVICE_BACKEND=openrc
  fi
  export DISTRO SERVICE_BACKEND
}
detect_wan() {
  ip -4 route show default 2>/dev/null | awk 'NR==1 {for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}'
}
detect_firewall() {
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qi 'Status: active'; then
    echo ufw
  elif command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    echo firewalld
  elif command -v iptables >/dev/null 2>&1; then
    echo iptables
  else
    echo none
  fi
}
metadata_dir() {
  printf '%s/interfaces/%s\n' "$STATE_ROOT" "$IFACE"
}
metadata_file() {
  printf '%s/metadata\n' "$(metadata_dir)"
}
ensure_state_dirs() {
  install -d -m 700 "$(metadata_dir)"
  install -d -m 700 "$STATE_ROOT/clients/$IFACE"
  install -d -m 700 "$ETC_ROOT"
}
read_metadata() {
  local file
  file=$(metadata_file)
  [[ -f $file ]] || die "Interface '$IFACE' is not managed by wg-manager. Check its name or run install first."
  # shellcheck disable=SC1090
  source "$file"
  MODE=${MODE:-}
  SUBNET=${SUBNET:-}
  IPV6=${IPV6:-}
  PORT=${PORT:-}
  ENDPOINT=${ENDPOINT:-}
  DNS=${DNS:-}
  MTU=${MTU:-1420}
  KEEPALIVE=${KEEPALIVE:-25}
  WAN=${WAN:-}
  FIREWALL=${FIREWALL:-}
  SERVICE_BACKEND=${SERVICE_BACKEND:-}
}
write_metadata() {
  local dir file
  dir=$(metadata_dir)
  file=$(metadata_file)
  install -d -m 700 "$dir"
  cat >"$file" <<EOF
MODE=$MODE
IFACE=$IFACE
SUBNET=$SUBNET
IPV6=$IPV6
PORT=$PORT
ENDPOINT=$ENDPOINT
DNS=$DNS
MTU=$MTU
KEEPALIVE=$KEEPALIVE
WAN=${WAN:-}
FIREWALL=${FIREWALL:-}
SERVICE_BACKEND=${SERVICE_BACKEND:-}
CREATED_AT=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
EOF
  chmod 600 "$file"
}

# Package database: command -> distro -> package name
# Required commands
declare -A PKG_WG=(
  [debian]="wireguard-tools" [ubuntu]="wireguard-tools"
  [fedora]="wireguard-tools" [rhel]="wireguard-tools" [rocky]="wireguard-tools" [almalinux]="wireguard-tools"
  [arch]="wireguard-tools" [alpine]="wireguard-tools"
)
declare -A PKG_WG_QUICK=(
  [debian]="wireguard-tools" [ubuntu]="wireguard-tools"
  [fedora]="wireguard-tools" [rhel]="wireguard-tools" [rocky]="wireguard-tools" [almalinux]="wireguard-tools"
  [arch]="wireguard-tools" [alpine]="wireguard-tools"
)
declare -A PKG_IP=(
  [debian]="iproute2" [ubuntu]="iproute2"
  [fedora]="iproute" [rhel]="iproute" [rocky]="iproute" [almalinux]="iproute"
  [arch]="iproute2" [alpine]="iproute2"
)
declare -A PKG_SS=(
  [debian]="iproute2" [ubuntu]="iproute2"
  [fedora]="iproute" [rhel]="iproute" [rocky]="iproute" [almalinux]="iproute"
  [arch]="iproute2" [alpine]="iproute2"
)
declare -A PKG_PYTHON3=(
  [debian]="python3" [ubuntu]="python3"
  [fedora]="python3" [rhel]="python3" [rocky]="python3" [almalinux]="python3"
  [arch]="python" [alpine]="python3"
)
declare -A PKG_SYSCTL=(
  [debian]="procps" [ubuntu]="procps"
  [fedora]="procps-ng" [rhel]="procps-ng" [rocky]="procps-ng" [almalinux]="procps-ng"
  [arch]="procps-ng" [alpine]="procps"
)
declare -A PKG_AWK=(
  [debian]="gawk" [ubuntu]="gawk"
  [fedora]="gawk" [rhel]="gawk" [rocky]="gawk" [almalinux]="gawk"
  [arch]="gawk" [alpine]="gawk"
)
declare -A PKG_CAT=(
  [debian]="coreutils" [ubuntu]="coreutils"
  [fedora]="coreutils" [rhel]="coreutils" [rocky]="coreutils" [almalinux]="coreutils"
  [arch]="coreutils" [alpine]="coreutils"
)
declare -A PKG_CHMOD=(
  [debian]="coreutils" [ubuntu]="coreutils"
  [fedora]="coreutils" [rhel]="coreutils" [rocky]="coreutils" [almalinux]="coreutils"
  [arch]="coreutils" [alpine]="coreutils"
)
declare -A PKG_DATE=(
  [debian]="coreutils" [ubuntu]="coreutils"
  [fedora]="coreutils" [rhel]="coreutils" [rocky]="coreutils" [almalinux]="coreutils"
  [arch]="coreutils" [alpine]="coreutils"
)
declare -A PKG_FIND=(
  [debian]="findutils" [ubuntu]="findutils"
  [fedora]="findutils" [rhel]="findutils" [rocky]="findutils" [almalinux]="findutils"
  [arch]="findutils" [alpine]="findutils"
)
declare -A PKG_GETENT=(
  [debian]="glibc" [ubuntu]="glibc"
  [fedora]="glibc" [rhel]="glibc" [rocky]="glibc" [almalinux]="glibc"
  [arch]="glibc" [alpine]="musl-utils"
)
declare -A PKG_GREP=(
  [debian]="grep" [ubuntu]="grep"
  [fedora]="grep" [rhel]="grep" [rocky]="grep" [almalinux]="grep"
  [arch]="grep" [alpine]="grep"
)
declare -A PKG_HEAD=(
  [debian]="coreutils" [ubuntu]="coreutils"
  [fedora]="coreutils" [rhel]="coreutils" [rocky]="coreutils" [almalinux]="coreutils"
  [arch]="coreutils" [alpine]="coreutils"
)
declare -A PKG_INSTALL=(
  [debian]="coreutils" [ubuntu]="coreutils"
  [fedora]="coreutils" [rhel]="coreutils" [rocky]="coreutils" [almalinux]="coreutils"
  [arch]="coreutils" [alpine]="coreutils"
)
declare -A PKG_MKDIR=(
  [debian]="coreutils" [ubuntu]="coreutils"
  [fedora]="coreutils" [rhel]="coreutils" [rocky]="coreutils" [almalinux]="coreutils"
  [arch]="coreutils" [alpine]="coreutils"
)
declare -A PKG_PASTE=(
  [debian]="coreutils" [ubuntu]="coreutils"
  [fedora]="coreutils" [rhel]="coreutils" [rocky]="coreutils" [almalinux]="coreutils"
  [arch]="coreutils" [alpine]="coreutils"
)
declare -A PKG_RM=(
  [debian]="coreutils" [ubuntu]="coreutils"
  [fedora]="coreutils" [rhel]="coreutils" [rocky]="coreutils" [almalinux]="coreutils"
  [arch]="coreutils" [alpine]="coreutils"
)
declare -A PKG_SED=(
  [debian]="sed" [ubuntu]="sed"
  [fedora]="sed" [rhel]="sed" [rocky]="sed" [almalinux]="sed"
  [arch]="sed" [alpine]="sed"
)
declare -A PKG_TAR=(
  [debian]="tar" [ubuntu]="tar"
  [fedora]="tar" [rhel]="tar" [rocky]="tar" [almalinux]="tar"
  [arch]="tar" [alpine]="tar"
)

# Optional commands
declare -A PKG_CURL=(
  [debian]="curl" [ubuntu]="curl"
  [fedora]="curl" [rhel]="curl" [rocky]="curl" [almalinux]="curl"
  [arch]="curl" [alpine]="curl"
)
declare -A PKG_QRENCODE=(
  [debian]="qrencode" [ubuntu]="qrencode"
  [fedora]="qrencode" [rhel]="qrencode" [rocky]="qrencode" [almalinux]="qrencode"
  [arch]="qrencode" [alpine]="qrencode"
)

# Firewall backends (at least one required)
declare -A PKG_UFW=(
  [debian]="ufw" [ubuntu]="ufw"
  [fedora]="ufw" [rhel]="ufw" [rocky]="ufw" [almalinux]="ufw"
  [arch]="ufw" [alpine]="ufw"
)
declare -A PKG_FIREWALLD=(
  [debian]="firewalld" [ubuntu]="firewalld"
  [fedora]="firewalld" [rhel]="firewalld" [rocky]="firewalld" [almalinux]="firewalld"
  [arch]="firewalld" [alpine]="firewalld"
)
declare -A PKG_IPTABLES=(
  [debian]="iptables" [ubuntu]="iptables"
  [fedora]="iptables" [rhel]="iptables" [rocky]="iptables" [almalinux]="iptables"
  [arch]="iptables" [alpine]="iptables"
)

pkg_install() {
  local -a pkgs=("$@")
  ((${#pkgs[@]} == 0)) && return 0
  case "$DISTRO" in
    debian|ubuntu)
      apt-get update && apt-get install -y "${pkgs[@]}"
      ;;
    fedora|rhel|rocky|almalinux)
      dnf install -y "${pkgs[@]}"
      ;;
    arch)
      pacman -Sy --noconfirm "${pkgs[@]}"
      ;;
    alpine)
      apk add "${pkgs[@]}"
      ;;
    *)
      die "Unsupported distribution '$DISTRO' for package installation."
      ;;
  esac
}

get_pkg_name() {
  local cmd=$1
  local distro_lc=${2:-${DISTRO,,}}
  case "$cmd" in
    wg|wg-quick) echo "wireguard-tools" ;;
    ip|ss)
      case "$distro_lc" in
        fedora|rhel|rocky|almalinux) echo "iproute" ;;
        *) echo "iproute2" ;;
      esac
      ;;
    python3)
      case "$distro_lc" in
        arch) echo "python" ;;
        *) echo "python3" ;;
      esac
      ;;
    sysctl)
      case "$distro_lc" in
        fedora|rhel|rocky|almalinux|arch) echo "procps-ng" ;;
        alpine) echo "procps" ;;
        *) echo "procps" ;;
      esac
      ;;
    awk) echo "gawk" ;;
    cat|chmod|date|install|mkdir|paste|rm|head) echo "coreutils" ;;
    find) echo "findutils" ;;
    getent)
      case "$distro_lc" in
        alpine) echo "musl-utils" ;;
        *) echo "glibc" ;;
      esac
      ;;
    grep) echo "grep" ;;
    sed) echo "sed" ;;
    tar) echo "tar" ;;
    curl) echo "curl" ;;
    qrencode) echo "qrencode" ;;
    ufw) echo "ufw" ;;
    firewall-cmd) echo "firewalld" ;;
    iptables) echo "iptables" ;;
    *) echo "unknown" ;;
  esac
}

check_requirements() {
  local mode=${1:-check}
  local -a required_commands=(
    "wg"
    "wg-quick"
    "ip"
    "ss"
    "python3"
    "sysctl"
    "awk"
    "cat"
    "chmod"
    "date"
    "find"
    "getent"
    "grep"
    "head"
    "install"
    "mkdir"
    "paste"
    "rm"
    "sed"
    "tar"
  )
  local -a optional_commands=(
    "curl"
    "qrencode"
  )
  local -a firewall_commands=(
    "ufw"
    "firewall-cmd"
    "iptables"
  )

  local cmd pkg_name status missing_required=() missing_optional=() missing_firewall=()
  local distro_lc=${DISTRO,,}

  printf 'Required:\n'
  printf '  Command       Package            Status\n'
  printf '  ────────────────────────────────────────────\n'
  for cmd in "${required_commands[@]}"; do
    pkg_name=$(get_pkg_name "$cmd" "$distro_lc")
    if command_available "$cmd"; then
      status="installed"
    else
      status="MISSING"
      missing_required+=("$cmd:$pkg_name")
    fi
    printf '  %-14s %-18s %s\n' "$cmd" "$pkg_name" "$status"
  done

  printf '\nOptional:\n'
  printf '  Command       Package            Status\n'
  printf '  ────────────────────────────────────────────\n'
  for cmd in "${optional_commands[@]}"; do
    pkg_name=$(get_pkg_name "$cmd" "$distro_lc")
    if command_available "$cmd"; then
      status="installed"
    else
      status="MISSING"
      missing_optional+=("$cmd:$pkg_name")
    fi
    printf '  %-14s %-18s %s\n' "$cmd" "$pkg_name" "$status"
  done

  local firewall_status="none"
  for cmd in "${firewall_commands[@]}"; do
    pkg_name=$(get_pkg_name "$cmd" "$distro_lc")
    if command_available "$cmd"; then
      if [[ $cmd == "ufw" ]]; then
        ufw status 2>/dev/null | grep -qi 'Status: active' && firewall_status="ufw" || firewall_status="ufw (inactive)"
      elif [[ $cmd == "firewall-cmd" ]]; then
        firewall-cmd --state >/dev/null 2>&1 && firewall_status="firewalld" || firewall_status="firewalld (inactive)"
      else
        firewall_status="iptables"
      fi
    fi
  done

  if [[ $firewall_status == "none" ]]; then
    missing_firewall=("firewall backend:ufw (recommended)")
  fi

  printf '\n'
  if ((${#missing_required[@]} > 0)); then
    printf 'Missing required packages:\n'
    for m in "${missing_required[@]}"; do
      printf '  %s -> %s\n' "${m%%:*}" "${m#*:}"
    done
  else
    printf 'All required commands available.\n'
  fi

  if ((${#missing_optional[@]} > 0)); then
    printf '\nMissing optional packages:\n'
    for m in "${missing_optional[@]}"; do
      printf '  %s -> %s\n' "${m%%:*}" "${m#*:}"
    done
  fi

  if ((${#missing_firewall[@]} > 0)); then
    printf '\nNo active firewall backend. Install one of: ufw, firewalld, or iptables.\n'
  fi

  if [[ $mode == "install" ]]; then
    if ((${#missing_required[@]} == 0 && ${#missing_firewall[@]} == 0)); then
      printf '\nNothing to install.\n'
      return 0
    fi
    local -a to_install=()
    local seen=()
    for m in "${missing_required[@]}"; do
      pkg_name=${m#*:}
      [[ " ${seen[*]} " == *" $pkg_name "* ]] || { to_install+=("$pkg_name"); seen+=("$pkg_name"); }
    done
    for m in "${missing_firewall[@]}"; do
      pkg_name=${m#*:}
      [[ " ${seen[*]} " == *" $pkg_name "* ]] || { to_install+=("$pkg_name"); seen+=("$pkg_name"); }
    done
    if ((${#to_install[@]} > 0)); then
      printf '\nWill install: %s\n' "${to_install[*]}"
      confirm "Proceed with installation?" || { printf 'Cancelled.\n'; return 1; }
      pkg_install "${to_install[@]}" || die "Package installation failed."
      printf '\nInstallation complete. Re-checking...\n'
      check_requirements check
    fi
  fi
}
