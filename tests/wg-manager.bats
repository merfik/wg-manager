#!/usr/bin/env bats

setup() {
  export WG_MANAGER_STATE_ROOT="$BATS_TEST_TMPDIR/state"
  export WG_MANAGER_ETC_ROOT="$BATS_TEST_TMPDIR/etc"
  export WG_MANAGER_SYSCTL_DIR="$BATS_TEST_TMPDIR/sysctl"
  export WG_MANAGER_UNIT_DIR="$BATS_TEST_TMPDIR/systemd"
  export WG_MANAGER_OPENRC_CONF_DIR="$BATS_TEST_TMPDIR/openrc-conf"
  export WG_MANAGER_OPENRC_UNIT_DIR="$BATS_TEST_TMPDIR/openrc-init"
  source "$BATS_TEST_DIRNAME/../wg-manager.sh"
  IFACE=wg0
  SUBNET=10.7.0.0/24
  MTU=1420
  KEEPALIVE=25
  PORT=51820
  DNS=system
  IPV6=
  MODE=hub
  SPLIT_TUNNEL=0
  ROUTES=
  ENDPOINT=192.0.2.10
  mkdir -p "$WG_MANAGER_STATE_ROOT/interfaces/wg0" "$WG_MANAGER_STATE_ROOT/clients/wg0" "$WG_MANAGER_ETC_ROOT"
}

@test "rejects invalid interface names" {
  IFACE='bad name'
  run validate_iface
  [ "$status" -ne 0 ]
  [[ "$output" == *"Invalid interface name"* ]]
}

@test "rejects invalid port" {
  PORT=70000
  run validate_port
  [ "$status" -ne 0 ]
  [[ "$output" == *"Invalid listen port"* ]]
}

@test "rejects invalid MTU" {
  MTU=1200
  run validate_mtu
  [ "$status" -ne 0 ]
  [[ "$output" == *"Invalid MTU"* ]]
}

@test "validates IPv4 CIDR" {
  run validate_cidr 10.7.0.0/24
  [ "$status" -eq 0 ]
  run validate_cidr 999.7.0.0/24
  [ "$status" -ne 0 ]
}

@test "hub config uses tunnel subnet" {
  MODE=hub
  output=$(generate_client_config phone 10.7.0.2/24 private-key server-key "")
  [[ "$output" == *"AllowedIPs = 10.7.0.0/24"* ]]
  [[ "$output" != *"DNS ="* ]]
}

@test "full config uses all traffic and DNS" {
  MODE=full
  DNS=cloudflare
  output=$(generate_client_config phone 10.7.0.2/24 private-key server-key "")
  [[ "$output" == *"AllowedIPs = 0.0.0.0/0"* ]]
  [[ "$output" != *"::/0"* ]]
  [[ "$output" == *"DNS = 1.1.1.1,1.0.0.1"* ]]
}

@test "metadata stores and reads mode" {
  MODE=full
  WAN=eth0
  FIREWALL=iptables
  SERVICE_BACKEND=systemd
  write_metadata
  MODE=
  read_metadata
  [ "$MODE" = full ]
  [ "$WAN" = eth0 ]
  [ "$(stat -c %a "$BATS_TEST_TMPDIR/state/interfaces/wg0/metadata")" = 600 ]
}

@test "entry point loads feature modules without starting the menu" {
  declare -F command_install >/dev/null
  declare -F command_add >/dev/null
  declare -F command_doctor >/dev/null
  declare -F menu_interface >/dev/null
}

@test "installer selects an unused default interface name" {
  [ "$(menu_default_iface)" = wg1 ]
  mkdir -p "$BATS_TEST_TMPDIR/etc/wg1.conf"
  [ "$(menu_default_iface)" = wg2 ]
}

@test "install wizard sends validated settings to the install handler" {
  command_install() {
    [ "$IFACE" = wg1 ]
    [ "$MODE" = hub ]
    [ "$SUBNET" = 10.7.0.0/24 ]
    [ "$PORT" = 51820 ]
    [ "$ENDPOINT" = vpn.example.com ]
    [ "$DRY_RUN" = 0 ]
    INSTALL_SUCCEEDED=1
    printf 'install handler received settings\n'
  }
  menu_install >"$BATS_TEST_TMPDIR/install-menu-output" < <(printf '\n1\n\n\n\n\n\nvpn.example.com\ny\nn\nn\n')
  output=$(cat "$BATS_TEST_TMPDIR/install-menu-output")
  [[ "$output" == *"Installation summary"* ]]
  [[ "$output" == *"install handler received settings"* ]]
}

@test "main opens the menu and exits on the exit choice" {
  output=$(main < <(printf '0\n'))
  [[ "$output" == *"WireGuard manager"* ]]
  [[ "$output" == *"No managed interfaces found."* ]]
}

@test "main routes managed interfaces to the management menu" {
  MODE=hub
  write_metadata
  command_list() {
    printf 'Mock client list for %s\n' "$IFACE"
  }
  output=$(main < <(printf '1\n3\n0\n0\n'))
  [[ "$output" == *"Interface wg0"* ]]
  [[ "$output" == *"Mock client list for wg0"* ]]
}

@test "interface menu dispatches a selected handler" {
  command_list() {
    printf 'Mock client list for %s\n' "$IFACE"
  }
  output=$(menu_interface < <(printf '3\n0\n'))
  [[ "$output" == *"Mock client list for wg0"* ]]
}

@test "legacy subcommands are rejected" {
  run main install
  [ "$status" -ne 0 ]
  [[ "$output" == *"replaced by interactive menus"* ]]
}

@test "unknown CLI arguments are rejected without dispatch" {
  command_remove() { printf 'remove-dispatched\n'; }
  run main --remove --iface wg0 --unexpected
  [ "$status" -ne 0 ]
  [[ "$output" == *"Unknown or invalid command-line arguments"* ]]
  [[ "$output" != *"remove-dispatched"* ]]
}

@test "multiple CLI commands are rejected" {
  run main --remove --add --iface wg0
  [ "$status" -ne 0 ]
  [[ "$output" == *"Only one command may be specified"* ]]
}

@test "validated menu prompts retry invalid values" {
  menu_prompt_validated PORT 'WireGuard port' 51820 validate_port < <(printf '70000\n51820\n')
  [ "$PORT" = 51820 ]
}

@test "dry-run menu selection reaches the handler and resets state" {
  dry_run_probe() {
    [ "$DRY_RUN" = 1 ]
    printf 'dry run requested\n'
  }
  menu_run_with_dry_run dry_run_probe >"$BATS_TEST_TMPDIR/dry-run-output" < <(printf 'yes\n')
  output=$(cat "$BATS_TEST_TMPDIR/dry-run-output")
  [[ "$output" == *"dry run requested"* ]]
  [ "$DRY_RUN" = 0 ]
  [ "$MENU_LAST_DRY_RUN" = 1 ]
}

@test "help describes the menu-only interface" {
  run main --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Run without arguments to open the interactive"* ]]
}

@test "prepare check runs without root and shows requirements table" {
  command_available() {
    case "$1" in
      wg|wg-quick|ip|ss|python3|sysctl|awk|cat|chmod|date|find|getent|grep|head|install|mkdir|paste|rm|sed|tar) return 0 ;;
      curl|qrencode) return 1 ;;
      ufw|firewall-cmd|iptables) return 1 ;;
    esac
  }
  distro_detect() { DISTRO=ubuntu; SERVICE_BACKEND=systemd; export DISTRO SERVICE_BACKEND; }
  run command_prepare check
  [ "$status" -eq 0 ]
  [[ "$output" == *"Checking system requirements for ubuntu"* ]]
  [[ "$output" == *"Required:"* ]]
  [[ "$output" == *"Optional:"* ]]
  [[ "$output" == *"MISSING"* ]]
}

@test "prepare check shows installed status for available commands" {
  command_available() { return 0; }
  distro_detect() { DISTRO=debian; SERVICE_BACKEND=systemd; export DISTRO SERVICE_BACKEND; }
  run command_prepare check
  [ "$status" -eq 0 ]
  [[ "$output" == *"installed"* ]]
  [[ "$output" != *"MISSING"* ]]
}

@test "prepare install requires root" {
  command_available() { return 0; }
  distro_detect() { DISTRO=debian; SERVICE_BACKEND=systemd; export DISTRO SERVICE_BACKEND; }
  run command_prepare install
  [ "$status" -ne 0 ]
  [[ "$output" == *"Root access is required"* ]]
}

@test "pkg_install dispatches to correct package manager" {
  DISTRO=ubuntu
  apt-get() { echo "apt-get $*"; }
  run pkg_install wireguard-tools ufw
  [ "$status" -eq 0 ]
  [[ "$output" == *"apt-get update"* ]]
  [[ "$output" == *"apt-get install -y wireguard-tools ufw"* ]]

  DISTRO=fedora
  dnf() { echo "dnf $*"; }
  run pkg_install wireguard-tools firewalld
  [ "$status" -eq 0 ]
  [[ "$output" == *"dnf install -y wireguard-tools firewalld"* ]]

  DISTRO=arch
  pacman() { echo "pacman $*"; }
  run pkg_install wireguard-tools ufw
  [ "$status" -eq 0 ]
  [[ "$output" == *"pacman -Sy --noconfirm wireguard-tools ufw"* ]]

  DISTRO=alpine
  apk() { echo "apk $*"; }
  run pkg_install wireguard-tools iptables
  [ "$status" -eq 0 ]
  [[ "$output" == *"apk add wireguard-tools iptables"* ]]
}

@test "get_pkg_name returns correct package for ubuntu" {
  [ "$(get_pkg_name wg ubuntu)" = "wireguard-tools" ]
  [ "$(get_pkg_name python3 ubuntu)" = "python3" ]
  [ "$(get_pkg_name ip ubuntu)" = "iproute2" ]
  [ "$(get_pkg_name ip fedora)" = "iproute" ]
  [ "$(get_pkg_name sysctl fedora)" = "procps-ng" ]
  [ "$(get_pkg_name sysctl ubuntu)" = "procps" ]
  [ "$(get_pkg_name getent alpine)" = "musl-utils" ]
  [ "$(get_pkg_name getent ubuntu)" = "glibc" ]
  [ "$(get_pkg_name ufw ubuntu)" = "ufw" ]
  [ "$(get_pkg_name firewall-cmd fedora)" = "firewalld" ]
  [ "$(get_pkg_name iptables alpine)" = "iptables" ]
  [ "$(get_pkg_name curl debian)" = "curl" ]
  [ "$(get_pkg_name qrencode arch)" = "qrencode" ]
}

@test "get_pkg_name returns correct package for arch" {
  [ "$(get_pkg_name python3 arch)" = "python" ]
  [ "$(get_pkg_name sysctl arch)" = "procps-ng" ]
}

@test "metadata is parsed, never executed" {
  local marker="$BATS_TEST_TMPDIR/pwned"
  printf 'MODE=hub\nEVIL=$(touch %s)\n' "$marker" >"$BATS_TEST_TMPDIR/state/interfaces/wg0/metadata"
  run read_metadata
  [ "$status" -ne 0 ]
  [ ! -e "$marker" ]
  [[ "$output" == *"unexpected key 'EVIL'"* ]]

  printf 'MODE=hub\nSUBNET=$(touch %s)\n' "$marker" >"$BATS_TEST_TMPDIR/state/interfaces/wg0/metadata"
  run read_metadata
  [ "$status" -eq 0 ]
  [ ! -e "$marker" ]
  read_metadata
  [ "$SUBNET" = '$(touch '"$marker"')' ]
}

@test "metadata rejects an unexpected interface name" {
  printf 'IFACE=wg9\nMODE=hub\n' >"$BATS_TEST_TMPDIR/state/interfaces/wg0/metadata"
  run read_metadata
  [ "$status" -ne 0 ]
  [[ "$output" == *"names interface 'wg9'"* ]]
}

@test "metadata round-trips split-tunnel settings and leaves no temp files" {
  MODE=full
  WAN=eth0
  FIREWALL=ufw
  SERVICE_BACKEND=systemd
  SPLIT_TUNNEL=1
  ROUTES=192.168.50.0/24,192.168.60.0/24
  write_metadata
  MODE=
  ROUTES=
  SPLIT_TUNNEL=0
  read_metadata
  [ "$SPLIT_TUNNEL" = 1 ]
  [ "$ROUTES" = "192.168.50.0/24,192.168.60.0/24" ]
  [ "$(stat -c %a "$BATS_TEST_TMPDIR/state/interfaces/wg0/metadata")" = 600 ]
  local leftovers=("$BATS_TEST_TMPDIR"/state/interfaces/wg0/.metadata.*)
  [ ! -e "${leftovers[0]}" ]
}

@test "preset files are parsed without executing values" {
  local preset="$BATS_TEST_TMPDIR/preset.env" marker="$BATS_TEST_TMPDIR/pwned"
  {
    printf '# comment line\n'
    printf 'WG_IFACE=wg5   # inline comment\n'
    printf 'WG_MODE="full"\n'
    printf 'WG_IPV6=        # empty\n'
    printf 'WG_WAN_IFACE=$(touch %s)\n' "$marker"
    printf 'WG_UNKNOWN=1\n'
    printf 'OTHER=2\n'
  } >"$preset"
  cli_parse --install --preset "$preset"
  cli_load_preset >"$BATS_TEST_TMPDIR/preset.out" 2>&1
  [ "$IFACE" = wg5 ]
  [ "$MODE" = full ]
  [ -z "$IPV6" ]
  [ "$WAN_OVERRIDE" = '$(touch '"$marker"')' ]
  [ ! -e "$marker" ]
  grep -q "Ignoring unknown preset variable 'WG_UNKNOWN'" "$BATS_TEST_TMPDIR/preset.out"
  grep -q "Ignoring non-WG variable 'OTHER'" "$BATS_TEST_TMPDIR/preset.out"
}

@test "preset client names are validated" {
  local preset="$BATS_TEST_TMPDIR/bad-client.env"
  printf 'WG_CLIENT=../evil\n' >"$preset"
  cli_parse --add --preset "$preset"
  run cli_load_preset
  [ "$status" -ne 0 ]
  [[ "$output" == *"Invalid client name"* ]]
}

@test "CIDR validation rejects leading zeros and out-of-range octets" {
  run validate_cidr 10.7.0.0/24
  [ "$status" -eq 0 ]
  run validate_cidr 10.7.0.0/0
  [ "$status" -eq 0 ]
  run validate_cidr 10.001.002.003/24
  [ "$status" -ne 0 ]
  run validate_cidr 999.7.0.0/24
  [ "$status" -ne 0 ]
  run validate_cidr 10.7.0.0/33
  [ "$status" -ne 0 ]
}

@test "client names are validated" {
  CLIENT=phone-1
  run validate_client
  [ "$status" -eq 0 ]
  CLIENT=../evil
  run validate_client
  [ "$status" -ne 0 ]
  CLIENT=.hidden
  run validate_client
  [ "$status" -ne 0 ]
}

@test "client addresses do not collide with the server or existing peers" {
  printf '[Interface]\nAddress = 10.7.0.1/24\n\n[Peer]\nPublicKey = x\nAllowedIPs = 10.7.0.2/32\n' >"$WG_MANAGER_ETC_ROOT/wg0.conf"
  [ "$(allocate_client_ip)" = "10.7.0.3/24" ]
}

@test "adding a client writes a /32 peer and rolls back when syncconf fails" {
  require_root() { return 0; }
  distro_detect() { DISTRO=debian; SERVICE_BACKEND=systemd; }
  generate_psk() { printf ''; }
  ip() { return 0; }
  wg() {
    case "$1" in
      genkey) printf 'PRIVATEKEY\n' ;;
      pubkey) cat >/dev/null; printf 'PUBLICKEY\n' ;;
      syncconf) printf 'boom\n' >&2; return 1 ;;
    esac
  }
  wg-quick() { printf '[Interface]\n'; }
  MODE=hub
  WAN=eth0
  FIREWALL=iptables
  SERVICE_BACKEND=systemd
  ENDPOINT=192.0.2.10
  write_metadata
  printf '[Interface]\nAddress = 10.7.0.1/24\nPrivateKey = k\nListenPort = 51820\n' >"$WG_MANAGER_ETC_ROOT/wg0.conf"
  CLIENT=phone
  run command_add
  [ "$status" -ne 0 ]
  [[ "$output" == *"rolled back"* ]]
  run grep -q '\[Peer\]' "$WG_MANAGER_ETC_ROOT/wg0.conf"
  [ "$status" -ne 0 ]
  [ ! -e "$WG_MANAGER_STATE_ROOT/clients/wg0/phone.conf" ]
  [ ! -e "$WG_MANAGER_STATE_ROOT/clients/wg0/phone.private" ]

  wg() {
    case "$1" in
      genkey) printf 'PRIVATEKEY\n' ;;
      pubkey) cat >/dev/null; printf 'PUBLICKEY\n' ;;
      syncconf) return 0 ;;
    esac
  }
  run command_add
  [ "$status" -eq 0 ]
  grep -q -- 'AllowedIPs = 10.7.0.2/32' "$WG_MANAGER_ETC_ROOT/wg0.conf"
  grep -q -- 'Address = 10.7.0.2/24' "$WG_MANAGER_STATE_ROOT/clients/wg0/phone.conf"
}

@test "removing a client handles CRLF configs" {
  require_root() { return 0; }
  distro_detect() { DISTRO=debian; SERVICE_BACKEND=systemd; }
  ip() { return 0; }
  wg() { return 0; }
  wg-quick() { printf 'stripped\n'; }
  MODE=hub
  WAN=eth0
  FIREWALL=iptables
  SERVICE_BACKEND=systemd
  ENDPOINT=192.0.2.10
  write_metadata
  printf '[Interface]\r\nAddress = 10.7.0.1/24\r\n\r\n[Peer]\r\n# phone\r\nPublicKey = KEYA\r\nAllowedIPs = 10.7.0.2/32\r\n\r\n[Peer]\r\n# laptop\r\nPublicKey = KEYB\r\nAllowedIPs = 10.7.0.3/32\r\n' >"$WG_MANAGER_ETC_ROOT/wg0.conf"
  printf 'KEYA\n' >"$WG_MANAGER_STATE_ROOT/clients/wg0/phone.public"
  printf 'conf\n' >"$WG_MANAGER_STATE_ROOT/clients/wg0/phone.conf"
  CLIENT=phone
  YES=1
  run command_remove
  [ "$status" -eq 0 ]
  run grep -q KEYB "$WG_MANAGER_ETC_ROOT/wg0.conf"
  [ "$status" -eq 0 ]
  run grep -q KEYA "$WG_MANAGER_ETC_ROOT/wg0.conf"
  [ "$status" -ne 0 ]
  [ ! -e "$WG_MANAGER_STATE_ROOT/clients/wg0/phone.conf" ]
}

@test "restore rejects archives with unexpected members" {
  require_root() { return 0; }
  local stage="$BATS_TEST_TMPDIR/tar"
  mkdir -p "$stage/${WG_MANAGER_STATE_ROOT#/}/interfaces/wg0" "$stage/etc"
  printf 'MODE=hub\n' >"$stage/${WG_MANAGER_STATE_ROOT#/}/interfaces/wg0/metadata"
  printf 'x\n' >"$stage/etc/passwd"
  tar -czf "$BATS_TEST_TMPDIR/bad.tar.gz" -C "$stage" etc/passwd "${WG_MANAGER_STATE_ROOT#/}/interfaces/wg0/metadata"
  ARGS=("$BATS_TEST_TMPDIR/bad.tar.gz")
  YES=1
  run command_restore
  [ "$status" -ne 0 ]
  [[ "$output" == *"unexpected path"* ]]
}

@test "restore rejects archives with symlink members" {
  require_root() { return 0; }
  local stage="$BATS_TEST_TMPDIR/tar2"
  mkdir -p "$stage/${WG_MANAGER_STATE_ROOT#/}/interfaces/wg0"
  printf 'MODE=hub\n' >"$stage/${WG_MANAGER_STATE_ROOT#/}/interfaces/wg0/metadata"
  ln -s /etc/passwd "$stage/${WG_MANAGER_STATE_ROOT#/}/interfaces/wg0/evil"
  tar -czf "$BATS_TEST_TMPDIR/link.tar.gz" -C "$stage" "${WG_MANAGER_STATE_ROOT#/}/interfaces/wg0/metadata" "${WG_MANAGER_STATE_ROOT#/}/interfaces/wg0/evil"
  ARGS=("$BATS_TEST_TMPDIR/link.tar.gz")
  YES=1
  run command_restore
  [ "$status" -ne 0 ]
  [[ "$output" == *"non-regular member"* ]]
}

@test "restore installs a valid archive into the managed roots" {
  require_root() { return 0; }
  enable_forwarding() { :; }
  add_firewall_rules() { :; }
  install_service() { :; }
  local stage="$BATS_TEST_TMPDIR/good"
  mkdir -p "$stage/${WG_MANAGER_STATE_ROOT#/}/interfaces/wg0" "$stage/${WG_MANAGER_ETC_ROOT#/}" "$stage/${WG_MANAGER_SYSCTL_DIR#/}"
  printf 'MODE=hub\nIFACE=wg0\nSUBNET=10.7.0.0/24\nIPV6=\nPORT=51820\nENDPOINT=192.0.2.10\nDNS=system\nMTU=1420\nKEEPALIVE=25\nWAN=eth0\nFIREWALL=iptables\nSERVICE_BACKEND=systemd\nSPLIT_TUNNEL=0\nROUTES=\nPSK=0\nCREATED_AT=2026-01-01T00:00:00Z\n' >"$stage/${WG_MANAGER_STATE_ROOT#/}/interfaces/wg0/metadata"
  printf '[Interface]\nAddress = 10.7.0.1/24\nPrivateKey = k\nListenPort = 51820\n' >"$stage/${WG_MANAGER_ETC_ROOT#/}/wg0.conf"
  printf 'net.ipv4.ip_forward=1\n' >"$stage/${WG_MANAGER_SYSCTL_DIR#/}/99-wg-manager-wg0.conf"
  tar -czf "$BATS_TEST_TMPDIR/good.tar.gz" -C "$stage" \
    "${WG_MANAGER_STATE_ROOT#/}/interfaces/wg0/metadata" \
    "${WG_MANAGER_ETC_ROOT#/}/wg0.conf" \
    "${WG_MANAGER_SYSCTL_DIR#/}/99-wg-manager-wg0.conf"
  ARGS=("$BATS_TEST_TMPDIR/good.tar.gz")
  YES=1
  MODE=
  SUBNET=
  command_restore
  [ "$MODE" = hub ]
  [ "$SUBNET" = 10.7.0.0/24 ]
  grep -q 'ListenPort = 51820' "$WG_MANAGER_ETC_ROOT/wg0.conf"
  grep -q 'net.ipv4.ip_forward=1' "$WG_MANAGER_SYSCTL_DIR/99-wg-manager-wg0.conf"
}

@test "restore removes stale interface and client state" {
  require_root() { return 0; }
  enable_forwarding() { :; }
  add_firewall_rules() { :; }
  install_service() { :; }
  mkdir -p "$WG_MANAGER_STATE_ROOT/interfaces/wg0" "$WG_MANAGER_STATE_ROOT/clients/wg0" "$WG_MANAGER_SYSCTL_DIR"
  printf 'stale\n' >"$WG_MANAGER_STATE_ROOT/interfaces/wg0/stale.key"
  printf 'stale\n' >"$WG_MANAGER_STATE_ROOT/clients/wg0/laptop.conf"
  printf 'stale\n' >"$WG_MANAGER_STATE_ROOT/clients/wg0/laptop.private"
  printf 'stale\n' >"$WG_MANAGER_SYSCTL_DIR/99-wg-manager-wg0.conf"

  local stage="$BATS_TEST_TMPDIR/stale-restore"
  mkdir -p "$stage/${WG_MANAGER_STATE_ROOT#/}/interfaces/wg0" "$stage/${WG_MANAGER_ETC_ROOT#/}" \
    "$stage/${WG_MANAGER_STATE_ROOT#/}/clients/wg0"
  printf 'MODE=hub\nIFACE=wg0\nSUBNET=10.7.0.0/24\nIPV6=\nPORT=51820\nENDPOINT=192.0.2.10\nDNS=system\nMTU=1420\nKEEPALIVE=25\nWAN=\nFIREWALL=iptables\nSERVICE_BACKEND=systemd\nSPLIT_TUNNEL=0\nROUTES=\nPSK=0\nCREATED_AT=2026-01-01T00:00:00Z\n' >"$stage/${WG_MANAGER_STATE_ROOT#/}/interfaces/wg0/metadata"
  printf '[Interface]\nAddress = 10.7.0.1/24\nPrivateKey = k\nListenPort = 51820\n' >"$stage/${WG_MANAGER_ETC_ROOT#/}/wg0.conf"
  printf 'Address = 10.7.0.2/24\n' >"$stage/${WG_MANAGER_STATE_ROOT#/}/clients/wg0/phone.conf"
  tar -czf "$BATS_TEST_TMPDIR/stale.tar.gz" -C "$stage" \
    "${WG_MANAGER_STATE_ROOT#/}/interfaces/wg0" \
    "${WG_MANAGER_STATE_ROOT#/}/clients/wg0" \
    "${WG_MANAGER_ETC_ROOT#/}/wg0.conf"

  ARGS=("$BATS_TEST_TMPDIR/stale.tar.gz")
  YES=1
  MODE=
  SUBNET=
  command_restore
  [ ! -e "$WG_MANAGER_STATE_ROOT/interfaces/wg0/stale.key" ]
  [ ! -e "$WG_MANAGER_STATE_ROOT/clients/wg0/laptop.conf" ]
  [ ! -e "$WG_MANAGER_STATE_ROOT/clients/wg0/laptop.private" ]
  [ -f "$WG_MANAGER_STATE_ROOT/clients/wg0/phone.conf" ]
  [ ! -e "$WG_MANAGER_SYSCTL_DIR/99-wg-manager-wg0.conf" ]
}

@test "restore dry run validates archive and preserves existing exit trap" {
  require_root() { return 0; }
  local stage="$BATS_TEST_TMPDIR/dry-run-restore"
  mkdir -p "$stage/${WG_MANAGER_STATE_ROOT#/}/interfaces/wg0" "$stage/${WG_MANAGER_ETC_ROOT#/}"
  printf 'MODE=hub\nIFACE=wg0\nSUBNET=10.7.0.0/24\nIPV6=\nPORT=51820\nENDPOINT=192.0.2.10\nDNS=system\nMTU=1420\nKEEPALIVE=25\nWAN=\nFIREWALL=iptables\nSERVICE_BACKEND=systemd\nSPLIT_TUNNEL=0\nROUTES=\nPSK=0\n' >"$stage/${WG_MANAGER_STATE_ROOT#/}/interfaces/wg0/metadata"
  printf '[Interface]\n' >"$stage/${WG_MANAGER_ETC_ROOT#/}/wg0.conf"
  tar -czf "$BATS_TEST_TMPDIR/dry-run.tar.gz" -C "$stage" \
    "${WG_MANAGER_STATE_ROOT#/}/interfaces/wg0/metadata" \
    "${WG_MANAGER_ETC_ROOT#/}/wg0.conf"
  ARGS=("$BATS_TEST_TMPDIR/dry-run.tar.gz")
  DRY_RUN=1
  local prior_trap
  prior_trap=$(trap -p EXIT || true)
  run command_restore
  [ "$status" -eq 0 ]
  [[ "$output" == *"validated backup for wg0"* ]]
  [ "$(trap -p EXIT || true)" = "$prior_trap" ]

  printf 'not a tar archive\n' >"$BATS_TEST_TMPDIR/not-an-archive"
  ARGS=("$BATS_TEST_TMPDIR/not-an-archive")
  run command_restore
  [ "$status" -ne 0 ]
  [[ "$output" == *"not a valid gzip tar archive"* ]]
}

@test "restore rejects invalid metadata before installing files" {
  require_root() { return 0; }
  local stage="$BATS_TEST_TMPDIR/bad-metadata"
  mkdir -p "$stage/${WG_MANAGER_STATE_ROOT#/}/interfaces/wg0" "$stage/${WG_MANAGER_ETC_ROOT#/}"
  printf 'MODE=hub\nIFACE=wg0\nSUBNET=not-a-cidr\nPORT=51820\nDNS=system\nFIREWALL=iptables\nSERVICE_BACKEND=systemd\n' >"$stage/${WG_MANAGER_STATE_ROOT#/}/interfaces/wg0/metadata"
  printf 'must not install\n' >"$stage/${WG_MANAGER_ETC_ROOT#/}/wg0.conf"
  tar -czf "$BATS_TEST_TMPDIR/bad-metadata.tar.gz" -C "$stage" \
    "${WG_MANAGER_STATE_ROOT#/}/interfaces/wg0/metadata" \
    "${WG_MANAGER_ETC_ROOT#/}/wg0.conf"
  ARGS=("$BATS_TEST_TMPDIR/bad-metadata.tar.gz")
  DRY_RUN=1
  run command_restore
  [ "$status" -ne 0 ]
  [ ! -e "$WG_MANAGER_ETC_ROOT/wg0.conf" ]
}

@test "backup refuses a symlink destination without changing its target" {
  require_root() { return 0; }
  MODE=hub
  WAN=
  FIREWALL=iptables
  SERVICE_BACKEND=systemd
  write_metadata
  printf 'sentinel\n' >"$BATS_TEST_TMPDIR/target"
  ln -s "$BATS_TEST_TMPDIR/target" "$BATS_TEST_TMPDIR/backup.tar.gz"
  OUTPUT="$BATS_TEST_TMPDIR/backup.tar.gz"
  run command_backup
  [ "$status" -ne 0 ]
  [ "$(cat "$BATS_TEST_TMPDIR/target")" = sentinel ]
}

@test "backup creates a private archive and refuses overwrite" {
  require_root() { return 0; }
  MODE=hub
  WAN=
  FIREWALL=iptables
  SERVICE_BACKEND=systemd
  write_metadata
  printf '[Interface]\n' >"$WG_MANAGER_ETC_ROOT/wg0.conf"
  mkdir -p "$WG_MANAGER_SYSCTL_DIR"
  printf 'net.ipv4.ip_forward=1\n' >"$WG_MANAGER_SYSCTL_DIR/99-wg-manager-wg0.conf"
  cd "$BATS_TEST_TMPDIR"
  OUTPUT=wg0-backup.tar.gz
  command_backup >/dev/null
  [ "$(stat -c %a "$OUTPUT")" = 600 ]
  run command_backup
  [ "$status" -ne 0 ]
  [[ "$output" == *"already exists"* ]]
}

@test "full-to-hub firewall cleanup removes only full-tunnel rules" {
  local calls="$BATS_TEST_TMPDIR/firewall-calls"
  : >"$calls"
  iptables() { printf '%s\n' "$*" >>"$calls"; }
  IFACE=wg0
  WAN=eth0
  MODE=hub
  remove_full_tunnel_rules iptables
  [ "$(cat "$calls")" = "-t nat -D POSTROUTING -o eth0 -j MASQUERADE" ]
}

@test "UFW full-to-hub cleanup retains the interface port rule" {
  local rules="$BATS_TEST_TMPDIR/reconfigure-before.rules" calls="$BATS_TEST_TMPDIR/ufw-calls"
  printf '# BEGIN wg-manager wg0\n*nat\nCOMMIT\n# END wg-manager wg0\n*filter\nCOMMIT\n' >"$rules"
  printf 'managed nat\n' >"$WG_MANAGER_STATE_ROOT/interfaces/wg0/ufw-nat.rules"
  export WG_MANAGER_UFW_RULES=$rules
  : >"$calls"
  ufw() { printf '%s\n' "$*" >>"$calls"; }
  IFACE=wg0
  WAN=eth0
  DRY_RUN=0
  remove_full_tunnel_rules ufw
  grep -q '^route delete allow in on wg0 out on eth0$' "$calls"
  ! grep -q 'delete allow 51820/udp' "$calls"
  ! grep -q 'BEGIN wg-manager wg0' "$rules"
  [ ! -e "$WG_MANAGER_STATE_ROOT/interfaces/wg0/ufw-nat.rules" ]
}

@test "firewalld full-to-hub cleanup removes only external NAT routing" {
  local calls="$BATS_TEST_TMPDIR/firewalld-calls"
  : >"$calls"
  firewall-cmd() { printf '%s\n' "$*" >>"$calls"; }
  WAN=eth0
  remove_full_tunnel_rules firewalld
  grep -q '^--permanent --zone=external --remove-interface=eth0$' "$calls"
  grep -q '^--permanent --zone=external --remove-masquerade$' "$calls"
  grep -q '^--reload$' "$calls"
  ! grep -q -- '--remove-port' "$calls"
}

@test "firewalld cleanup preserves NAT used by another full-tunnel interface" {
  local calls="$BATS_TEST_TMPDIR/firewalld-shared-calls"
  : >"$calls"
  firewall-cmd() { printf '%s\n' "$*" >>"$calls"; }
  mkdir -p "$WG_MANAGER_STATE_ROOT/interfaces/wg0" "$WG_MANAGER_STATE_ROOT/interfaces/wg1"
  printf 'IFACE=wg0\nMODE=full\nWAN=eth0\n' >"$WG_MANAGER_STATE_ROOT/interfaces/wg0/metadata"
  printf 'IFACE=wg1\nMODE=full\nWAN=eth0\n' >"$WG_MANAGER_STATE_ROOT/interfaces/wg1/metadata"
  IFACE=wg0
  WAN=eth0
  remove_full_tunnel_rules firewalld
  ! grep -q -- '--remove-interface=eth0' "$calls"
  ! grep -q -- '--remove-masquerade' "$calls"
  grep -q '^--reload$' "$calls"

  printf 'IFACE=wg1\nMODE=hub\nWAN=\n' >"$WG_MANAGER_STATE_ROOT/interfaces/wg1/metadata"
  : >"$calls"
  remove_full_tunnel_rules firewalld
  grep -q '^--permanent --zone=external --remove-interface=eth0$' "$calls"
  grep -q '^--permanent --zone=external --remove-masquerade$' "$calls"
}

@test "reconfiguring full to hub preserves baseline firewall rules" {
  require_root() { return 0; }
  MODE=full
  WAN=eth0
  FIREWALL=iptables
  SERVICE_BACKEND=systemd
  write_metadata
  mkdir -p "$WG_MANAGER_STATE_ROOT/clients/wg0"
  printf 'AllowedIPs = 0.0.0.0/0\n' >"$WG_MANAGER_STATE_ROOT/clients/wg0/phone.conf"
  MODE_ARG=hub
  YES=1
  add_firewall_rules() { [ "$MODE" = hub ]; }
  remove_firewall_rules() { return 99; }
  remove_full_tunnel_rules() { [ "$1" = iptables ]; }
  install_service() { :; }
  command_reconfigure
  [ "$MODE" = hub ]
  grep -q 'AllowedIPs = 10.7.0.0/24' "$WG_MANAGER_STATE_ROOT/clients/wg0/phone.conf"
  grep -q '^MODE=hub$' "$WG_MANAGER_STATE_ROOT/interfaces/wg0/metadata"
}

@test "UFW setup errors are reported" {
  ufw() { return 1; }
  DRY_RUN=0
  run add_firewall_rules ufw
  [ "$status" -ne 0 ]
  [[ "$output" == *"Could not allow UDP port"* ]]
}

@test "UFW NAT removal failure preserves its state mirror" {
  local rules="$BATS_TEST_TMPDIR/before-fail.rules"
  printf '# BEGIN wg-manager wg0\n*nat\nCOMMIT\n# END wg-manager wg0\n*filter\nCOMMIT\n' >"$rules"
  export WG_MANAGER_UFW_RULES=$rules
  printf 'managed nat\n' >"$WG_MANAGER_STATE_ROOT/interfaces/wg0/ufw-nat.rules"
  ufw() { return 1; }
  run remove_ufw_nat
  [ "$status" -ne 0 ]
  [ -f "$WG_MANAGER_STATE_ROOT/interfaces/wg0/ufw-nat.rules" ]
}

@test "ufw NAT block is inserted before the filter section and removed cleanly" {
  local rules="$BATS_TEST_TMPDIR/before.rules" orig_mode
  printf '*filter\n:ufw-before-input - [0:0]\nCOMMIT\n' >"$rules"
  orig_mode=$(stat -c %a "$rules")
  export WG_MANAGER_UFW_RULES=$rules
  WAN=eth0
  IFACE=wg0
  MODE=full
  ufw() { printf 'ufw %s\n' "$*"; }
  iptables() { printf -- '-A POSTROUTING -o eth0 -j MASQUERADE\n'; }
  apply_ufw_nat eth0
  grep -q '# BEGIN wg-manager wg0' "$rules"
  grep -q -- '-A POSTROUTING -o eth0 -j MASQUERADE' "$rules"
  awk '/# BEGIN wg-manager/{b=NR} /^\*filter/{f=NR} END{exit !(b && f && b<f)}' "$rules"
  [ -f "$WG_MANAGER_STATE_ROOT/interfaces/wg0/ufw-nat.rules" ]
  [ "$(stat -c %a "$rules")" = "$orig_mode" ]
  apply_ufw_nat eth0
  [ "$(grep -c '# BEGIN wg-manager wg0' "$rules")" = 1 ]
  remove_ufw_nat
  run grep -q MASQUERADE "$rules"
  [ "$status" -ne 0 ]
  [ "$(cat "$rules")" = "$(printf '*filter\n:ufw-before-input - [0:0]\nCOMMIT\n')" ]
  [ "$(stat -c %a "$rules")" = "$orig_mode" ]
}
