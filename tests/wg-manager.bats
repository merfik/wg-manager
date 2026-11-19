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
  [[ "$output" == *"AllowedIPs = 0.0.0.0/0, ::/0"* ]]
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
