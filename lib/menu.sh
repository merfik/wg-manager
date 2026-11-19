# shellcheck shell=bash
managed_interfaces() {
  MANAGED_INTERFACES=()
  local dir iface
  for dir in "$STATE_ROOT"/interfaces/*; do
    [[ -f $dir/metadata ]] || continue
    iface=${dir##*/}
    [[ $iface =~ ^[A-Za-z][A-Za-z0-9_.-]{0,14}$ ]] || continue
    MANAGED_INTERFACES+=("$iface")
  done
}

menu_default_iface() {
  local number=0 candidate
  while true; do
    candidate="wg$number"
    if [[ ! -e "$ETC_ROOT/$candidate.conf" &&
      ! -e "$STATE_ROOT/interfaces/$candidate" &&
      ! -e "$STATE_ROOT/clients/$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
    ((number += 1))
  done
}

menu_read_value() {
  local prompt=$1 default=${2:-} value
  if [[ -n $default ]]; then
    read -r -p "$prompt [$default]: " value || return 1
    MENU_VALUE=${value:-$default}
  else
    read -r -p "$prompt: " MENU_VALUE || return 1
  fi
}

menu_prompt_validated() {
  local variable=$1 prompt=$2 default=$3 validator=$4 value
  while true; do
    menu_read_value "$prompt" "$default" || return 1
    value=$MENU_VALUE
    printf -v "$variable" '%s' "$value"
    if [[ $validator == validate_cidr ]]; then
      if validate_cidr "$value"; then return 0; fi
    elif "$validator"; then
      return 0
    fi
  done
}

menu_prompt_mode() {
  local choice
  while true; do
    printf 'Select tunnel mode:\n  1) Hub-and-spoke\n  2) Full-tunnel VPN\n'
    read -r -p 'Mode [1]: ' choice || return 1
    case ${choice:-1} in
      1) MODE=hub; return 0 ;;
      2) MODE=full; return 0 ;;
      *) printf 'Choose 1 or 2.\n' >&2 ;;
    esac
  done
}

menu_confirm_default_yes() {
  local prompt=$1 reply
  read -r -p "$prompt [Y/n] " reply || return 1
  [[ -z $reply || ${reply,,} == y || ${reply,,} == yes ]]
}

menu_confirm_default_no() {
  local prompt=$1 reply
  read -r -p "$prompt [y/N] " reply || return 1
  [[ ${reply,,} == y || ${reply,,} == yes ]]
}

menu_run_with_dry_run() {
  local action=$1 reply status
  DRY_RUN=0
  while true; do
    read -r -p 'Run as a dry run only? [y/N] ' reply || {
      MENU_ACTION_CANCELLED=1
      return 0
    }
    case ${reply,,} in
      y|yes) DRY_RUN=1; break ;;
      ''|n|no) break ;;
      *) printf 'Enter yes or no.\n' >&2 ;;
    esac
  done
  MENU_ACTION_CANCELLED=0
  MENU_LAST_DRY_RUN=$DRY_RUN
  if "$action"; then status=0; else status=$?; fi
  DRY_RUN=0
  return "$status"
}

menu_prompt_endpoint() {
  local required=$1
  while true; do
    menu_read_value 'Public endpoint (IP or hostname)' '' || return 1
    ENDPOINT=$MENU_VALUE
    if [[ -z $ENDPOINT && $required == 0 ]]; then return 0; fi
    if [[ -n $ENDPOINT ]] && validate_endpoint; then return 0; fi
    [[ -n $ENDPOINT ]] || log ERROR 'An endpoint is required for hub mode.'
  done
}

menu_prompt_ipv6() {
  while true; do
    menu_read_value 'Optional IPv6 ULA CIDR (leave blank to skip)' '' || return 1
    IPV6=$MENU_VALUE
    if validate_ipv6; then return 0; fi
  done
}

menu_prompt_routes() {
  local route
  while true; do
    menu_read_value 'Comma-separated IPv4 routes (leave blank for none)' '' || return 1
    ROUTES=$MENU_VALUE
    [[ -n $ROUTES ]] || return 0
    local valid=1
    local -a route_list=()
    IFS=, read -r -a route_list <<<"$ROUTES"
    for route in "${route_list[@]}"; do
      route=${route//[[:space:]]/}
      if ! validate_cidr "$route"; then valid=0; fi
    done
    [[ $valid == 1 ]] && return 0
  done
}

menu_prompt_client() {
  while true; do
    menu_read_value 'Client name (letters, digits, dot, underscore, hyphen)' '' || return 1
    CLIENT=$MENU_VALUE
    if validate_client; then return 0; fi
  done
}

menu_prompt_install_settings() {
  IFACE=$(menu_default_iface)
  SUBNET=10.7.0.0/24
  IPV6=
  PORT=51820
  ENDPOINT=
  DNS=system
  MTU=1420
  KEEPALIVE=25
  PSK=0
  export YES=0
  DRY_RUN=0
  export LOG_FILE=
  export SPLIT_TUNNEL=0
  ROUTES=

  menu_prompt_validated IFACE 'Interface name' "$IFACE" validate_iface || return 1
  menu_prompt_mode || return 1
  menu_prompt_validated SUBNET 'IPv4 tunnel subnet' "$SUBNET" validate_cidr || return 1
  menu_prompt_validated PORT 'WireGuard UDP port' "$PORT" validate_port || return 1
  menu_prompt_validated MTU 'Client MTU' "$MTU" validate_mtu || return 1
  menu_prompt_validated KEEPALIVE 'Persistent keepalive in seconds (0 disables it)' "$KEEPALIVE" validate_keepalive || return 1
  menu_prompt_ipv6 || return 1
  menu_prompt_endpoint "$([[ $MODE == hub ]] && echo 1 || echo 0)" || return 1
  if [[ $MODE == full ]]; then
    if menu_confirm_default_no 'Enable split-tunnel routes instead of sending all traffic through the VPN?'; then
      export SPLIT_TUNNEL=1
      menu_prompt_routes || return 1
    fi
  fi
}

menu_install() {
  menu_prompt_install_settings || return 0
  printf '\nInstallation summary\n  Interface: %s\n  Mode: %s\n  Tunnel subnet: %s\n  Port: %s/UDP\n  MTU: %s\n  IPv6: %s\n  DNS: %s\n  Endpoint: %s\n' \
    "$IFACE" "$MODE" "$SUBNET" "$PORT" "$MTU" "${IPV6:-disabled}" "$DNS" "${ENDPOINT:-automatic detection}"
  if ! menu_confirm_default_no 'Proceed with installation?'; then
    printf 'Installation canceled.\n'
    return 0
  fi
  menu_run_with_dry_run command_install
  [[ $MENU_ACTION_CANCELLED == 0 ]] || return 0
  [[ $MENU_LAST_DRY_RUN == 0 ]] || return 0
  [[ $INSTALL_SUCCEEDED == 1 ]] || return 0
  if menu_confirm_default_yes 'Add a client now?'; then
    menu_add_client
  fi
}

menu_add_client() {
  menu_prompt_client || return 0
  export PSK=0
  if menu_confirm_default_no 'Generate a preshared key for this client?'; then export PSK=1; fi
  command_add
}

menu_remove_client() {
  menu_prompt_client || return 0
  menu_run_with_dry_run command_remove
}

menu_show_client() {
  menu_prompt_client || return 0
  export QR=0
  if menu_confirm_default_no 'Also print a QR code in the terminal?'; then export QR=1; fi
  command_show
}

menu_export_client() {
  menu_prompt_client || return 0
  menu_read_value 'Export directory (leave blank for current directory)' '' || return 0
  export OUTPUT=$MENU_VALUE
  command_export
}

menu_reconfigure() {
  menu_prompt_mode || return 0
  MODE_ARG=$MODE
  MODE=
  menu_run_with_dry_run command_reconfigure
}

menu_backup() {
  menu_read_value 'Backup file (leave blank for a timestamped default)' '' || return 0
  export OUTPUT=$MENU_VALUE
  menu_run_with_dry_run command_backup
}

menu_restore() {
  menu_read_value 'Backup archive path' '' || return 0
  [[ -n $MENU_VALUE ]] || { log ERROR 'A backup archive path is required.'; return 0; }
  export ARGS=("$MENU_VALUE")
  menu_run_with_dry_run command_restore
}

menu_interface() {
  local choice
  while true; do
    printf '\nInterface %s\n' "$IFACE"
    cat <<'EOF'
  1) Add client
  2) Remove client
  3) List clients
  4) Show client config / QR
  5) Export client config / QR image
  6) Show status
  7) Run diagnostics
  8) Reconfigure hub/full mode
  9) Back up interface
 10) Restore backup
 11) Uninstall interface
  0) Back
EOF
    read -r -p 'Select an action: ' choice || return 0
    case "$choice" in
      1) menu_add_client ;;
      2) menu_remove_client ;;
      3) command_list ;;
      4) menu_show_client ;;
      5) menu_export_client ;;
      6)
        if ! command_status; then printf 'Status is unavailable; see the error above.\n' >&2; fi
        ;;
      7)
        if ! command_doctor; then printf 'Diagnostics reported issues; see the report above.\n' >&2; fi
        ;;
      8) menu_reconfigure ;;
      9) menu_backup ;;
      10) menu_restore ;;
      11)
        menu_run_with_dry_run command_uninstall
        [[ $MENU_ACTION_CANCELLED == 0 ]] || return 0
        [[ $MENU_LAST_DRY_RUN == 1 || $UNINSTALL_SUCCEEDED == 0 ]] || return 0
        ;;
      0) return 0 ;;
      *) printf 'Choose a listed action.\n' >&2 ;;
    esac
  done
}

menu_select_interface() {
  local i choice
  managed_interfaces
  ((${#MANAGED_INTERFACES[@]} > 0)) || return 1
  if ((${#MANAGED_INTERFACES[@]} == 1)); then
    IFACE=${MANAGED_INTERFACES[0]}
    return 0
  fi
  printf 'Managed interfaces:\n'
  for i in "${!MANAGED_INTERFACES[@]}"; do
    printf '  %d) %s\n' "$((i + 1))" "${MANAGED_INTERFACES[$i]}"
  done
  printf '  0) Back\n'
  while true; do
    read -r -p 'Select an interface: ' choice || return 1
    [[ $choice == 0 ]] && return 1
    if [[ $choice =~ ^[0-9]+$ ]] && (( 10#$choice >= 1 && 10#$choice <= ${#MANAGED_INTERFACES[@]} )); then
      IFACE=${MANAGED_INTERFACES[$((choice - 1))]}
      return 0
    fi
    printf 'Choose a listed interface.\n' >&2
  done
}

main_menu() {
  local choice
  while true; do
    managed_interfaces
    printf '\nWireGuard manager\n'
    if ((${#MANAGED_INTERFACES[@]} == 0)); then
      printf '  No managed interfaces found.\n  1) Prepare system (check/install dependencies)\n  2) Install WireGuard\n  0) Exit\n'
      read -r -p 'Select an action: ' choice || return 0
      case "$choice" in
        1) command_prepare check ;;
        2) menu_install ;;
        0) return 0 ;;
        *) printf 'Choose a listed action.\n' >&2 ;;
      esac
    else
      printf '  1) Manage an interface\n  2) Install an interface\n  3) Prepare system (check/install dependencies)\n  0) Exit\n'
      read -r -p 'Select an action: ' choice || return 0
      case "$choice" in
        1)
          if menu_select_interface; then menu_interface; fi
          ;;
        2) menu_install ;;
        3) command_prepare check ;;
        0) return 0 ;;
        *) printf 'Choose a listed action.\n' >&2 ;;
      esac
    fi
  done
}

main() {
  cli_parse "$@" || true  # unknown/legacy flags fall through to the legacy path
  if [[ -n $CLI_COMMAND ]]; then
    cli_load_preset
    cli_apply_flags
    cli_dispatch
    return $?
  fi
  if (($#)); then
    if (($# == 1)) && [[ $1 == --help || $1 == -h ]]; then
      usage
      return 0
    fi
    if (($# == 1)) && [[ $1 == --prepare ]]; then
      command_prepare check
      return 0
    fi
    if (($# == 1)) && [[ $1 == --prepare-install ]]; then
      require_root
      command_prepare install
      return 0
    fi
    die "The command-line interface has been replaced by interactive menus. Run '$PROGRAM' without arguments."
  fi
  main_menu
}
