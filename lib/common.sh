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
OUTPUT=""
CLIENT=""
QR=0
SPLIT_TUNNEL=0
ROUTES=""
WAN_OVERRIDE=""
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

CLI mode (non-interactive):
  --install            Install a new interface (requires preset/values)
  --add                Add a client (requires WG_CLIENT)
  --remove             Remove a client (requires WG_CLIENT)
  --list               List clients on the interface
  --status             Show interface status
  --doctor             Run diagnostics
  --backup             Back up the interface
  --restore            Restore from a backup (requires WG_BACKUP_FILE)
  --uninstall          Uninstall the interface
  --reconfigure        Switch an installed interface between hub and full mode
  --mode <hub|full>    Target mode for --reconfigure
  --preset <file>      Load preset variables from a .env file
  --iface <name>       Override the interface name
  --dry-run            Preview without making changes
  --yes | --auto       Auto-confirm all prompts

Preset variables (wg-preset.env): WG_IFACE, WG_MODE, WG_ENDPOINT, WG_SUBNET,
WG_PORT, WG_MTU, WG_KEEPALIVE, WG_IPV6, WG_DNS, WG_DNS_CUSTOM, WG_SPLIT_TUNNEL,
WG_SPLIT_ROUTES, WG_WAN_IFACE, WG_CLIENT, WG_PSK, WG_EXPORT_DIR, WG_QR,
WG_DRY_RUN, WG_BACKUP_FILE.

Options:
  --help             Show this help and exit.
  --prepare          Check system requirements and show missing packages (no root required).
  --prepare-install  Check requirements and install missing required packages (requires root).

Examples:
  sudo ./wg-manager.sh --install --preset wg-preset.env
  sudo ./wg-manager.sh --add --iface wg0 --preset wg-client-preset.env
  sudo ./wg-manager.sh --list --iface wg0
  sudo ./wg-manager.sh --install --preset wg-preset.env --dry-run
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
validate_client() {
  if [[ ! $CLIENT =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]{0,31}$ ]]; then
    log ERROR "Invalid client name '$CLIENT'. Use 1-32 letters, digits, dots, underscores, or hyphens, starting with a letter, digit, or underscore."
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
  local octet='(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])'
  if [[ ! $cidr =~ ^$octet(\.$octet){3}/(0|[12]?[0-9]|3[0-2])$ ]]; then
    log ERROR "Invalid CIDR '$cidr'. Use IPv4 notation such as 10.7.0.0/24."
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
ufw_rules_file() {
  printf '%s\n' "${WG_MANAGER_UFW_RULES:-/etc/ufw/before.rules}"
}
# Metadata and preset files are parsed, never sourced. Each line is split on the
# first '=' and the value is taken literally. An inline comment is stripped only
# when the '#' is preceded by whitespace, so values may contain '#'.
declare -gA KV=()
parse_kv_file() {
  local file=$1 line key value
  KV=()
  while IFS= read -r line || [[ -n $line ]]; do
    line=${line%$'\r'}
    [[ $line =~ ^[[:space:]]*(#|$) ]] && continue
    [[ $line =~ ^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*=(.*)$ ]] || return 1
    key=${BASH_REMATCH[1]}
    value=${BASH_REMATCH[2]}
    value=${value%%[[:space:]]#*}
    value=${value#"${value%%[![:space:]]*}"}
    value=${value%"${value##*[![:space:]]}"}
    if [[ ${#value} -ge 2 ]] && [[ $value == \"*\" || $value == \'*\' ]]; then
      value=${value:1:${#value}-2}
    fi
    KV[$key]=$value
  done <"$file"
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
  local file key
  file=$(metadata_file)
  [[ -f $file ]] || die "Interface '$IFACE' is not managed by wg-manager. Check its name or run install first."
  parse_kv_file "$file" || die "Metadata for '$IFACE' at $file is malformed. Reinstall the interface or restore a valid backup."
  for key in "${!KV[@]}"; do
    case $key in
      MODE|IFACE|SUBNET|IPV6|PORT|ENDPOINT|DNS|MTU|KEEPALIVE|WAN|FIREWALL|SERVICE_BACKEND|SPLIT_TUNNEL|ROUTES|PSK|CREATED_AT) ;;
      *) die "Metadata for '$IFACE' contains an unexpected key '$key'. Refusing to load it." ;;
    esac
  done
  if [[ -n ${KV[IFACE]:-} && ${KV[IFACE]} != "$IFACE" ]]; then
    die "Metadata for '$IFACE' names interface '${KV[IFACE]}'. Refusing to load mismatched state."
  fi
  validate_iface || die "Metadata for '$IFACE' contains an invalid interface name."
  MODE=${KV[MODE]:-}
  SUBNET=${KV[SUBNET]:-}
  IPV6=${KV[IPV6]:-}
  PORT=${KV[PORT]:-}
  ENDPOINT=${KV[ENDPOINT]:-}
  DNS=${KV[DNS]:-}
  MTU=${KV[MTU]:-1420}
  KEEPALIVE=${KV[KEEPALIVE]:-25}
  WAN=${KV[WAN]:-}
  FIREWALL=${KV[FIREWALL]:-}
  SERVICE_BACKEND=${KV[SERVICE_BACKEND]:-}
  SPLIT_TUNNEL=${KV[SPLIT_TUNNEL]:-0}
  ROUTES=${KV[ROUTES]:-}
  PSK=${KV[PSK]:-0}
}
write_metadata() {
  local dir file tmp name value
  dir=$(metadata_dir)
  file=$(metadata_file)
  install -d -m 700 "$dir"
  local -A values=(
    [MODE]=$MODE
    [IFACE]=$IFACE
    [SUBNET]=$SUBNET
    [IPV6]=$IPV6
    [PORT]=$PORT
    [ENDPOINT]=$ENDPOINT
    [DNS]=$DNS
    [MTU]=$MTU
    [KEEPALIVE]=$KEEPALIVE
    [WAN]=${WAN:-}
    [FIREWALL]=${FIREWALL:-}
    [SERVICE_BACKEND]=${SERVICE_BACKEND:-}
    [SPLIT_TUNNEL]=${SPLIT_TUNNEL:-0}
    [ROUTES]=${ROUTES:-}
    [PSK]=${PSK:-0}
  )
  for name in "${!values[@]}"; do
    value=${values[$name]}
    if [[ $value == *$'\n'* ]]; then
      die "Refusing to write metadata for '$IFACE': '$name' contains a newline."
    fi
  done
  tmp=$(mktemp "$dir/.metadata.XXXXXX")
  (
    umask 077
    {
      for name in MODE IFACE SUBNET IPV6 PORT ENDPOINT DNS MTU KEEPALIVE WAN FIREWALL SERVICE_BACKEND SPLIT_TUNNEL ROUTES PSK; do
        printf '%s=%s\n' "$name" "${values[$name]}"
      done
      printf 'CREATED_AT=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    } >"$tmp"
  )
  chmod 600 "$tmp"
  mv -f "$tmp" "$file"
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
