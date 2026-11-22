# shellcheck shell=bash
# lib/cli.sh — non-interactive CLI mode with preset files

# Globals set by cli_parse (used by cli_load_preset / cli_apply_flags).
CLI_COMMAND=
CLI_IFACE=
CLI_YES=
CLI_DRY_RUN=
WG_PRESET_FILE=

cli_parse() {
  CLI_COMMAND=
  CLI_IFACE=
  CLI_YES=
  CLI_DRY_RUN=
  while (($#)); do
    case $1 in
      --preset)
        [[ $# -ge 2 ]] || die "--preset requires a file path"
        WG_PRESET_FILE=$2
        shift 2
        ;;
      --install|--add|--remove|--list|--status|--doctor|--backup|--restore|--uninstall|--reconfigure)
        [[ -z $CLI_COMMAND ]] || die "Only one command may be specified."
        CLI_COMMAND=$1
        shift
        ;;
      --iface)
        [[ $# -ge 2 ]] || die "--iface requires an interface name"
        CLI_IFACE=$2
        shift 2
        ;;
      --mode)
        [[ $# -ge 2 ]] || die "--mode requires hub or full"
        [[ $2 =~ ^(hub|full)$ ]] || die "--mode must be hub or full"
        MODE_ARG=$2
        shift 2
        ;;
      --dry-run)
        CLI_DRY_RUN=1
        shift
        ;;
      --yes|--auto)
        CLI_YES=1
        shift
        ;;
      *)
        return 1
        ;;
    esac
  done
  return 0
}

cli_load_preset() {
  [[ -n $WG_PRESET_FILE ]] || return 0
  [[ -f $WG_PRESET_FILE ]] || die "Preset file '$WG_PRESET_FILE' not found"
  local key
  parse_kv_file "$WG_PRESET_FILE" || die "Preset file '$WG_PRESET_FILE' has a malformed line (expected KEY=VALUE)."
  for key in "${!KV[@]}"; do
    case $key in
      WG_IFACE|WG_MODE|WG_ENDPOINT|WG_SUBNET|WG_PORT|WG_MTU|WG_KEEPALIVE|WG_IPV6|WG_DNS|WG_DNS_CUSTOM|WG_SPLIT_TUNNEL|WG_SPLIT_ROUTES|WG_WAN_IFACE|WG_CLIENT|WG_PSK|WG_EXPORT_DIR|WG_QR|WG_DRY_RUN|WG_BACKUP_FILE)
        printf -v "$key" '%s' "${KV[$key]}"
        ;;
      WG_*)
        log WARN "Ignoring unknown preset variable '$key' in $WG_PRESET_FILE."
        ;;
      *)
        log WARN "Ignoring non-WG variable '$key' in $WG_PRESET_FILE."
        ;;
    esac
  done

  # Map preset variables (WG_*) onto the globals the command functions use.
  IFACE=${WG_IFACE:-$IFACE}
  MODE=${WG_MODE:-$MODE}
  ENDPOINT=${WG_ENDPOINT:-$ENDPOINT}
  SUBNET=${WG_SUBNET:-$SUBNET}
  PORT=${WG_PORT:-$PORT}
  MTU=${WG_MTU:-$MTU}
  KEEPALIVE=${WG_KEEPALIVE:-$KEEPALIVE}
  IPV6=${WG_IPV6:-$IPV6}
  ROUTES=${WG_SPLIT_ROUTES:-$ROUTES}
  if [[ ${WG_DNS:-} == custom ]]; then
    DNS=${WG_DNS_CUSTOM:-}
  else
    DNS=${WG_DNS:-$DNS}
  fi
  SPLIT_TUNNEL=$([[ ${WG_SPLIT_TUNNEL:-} == yes ]] && echo 1 || echo 0)
  WAN_OVERRIDE=${WG_WAN_IFACE:-}
  CLIENT=${WG_CLIENT:-$CLIENT}
  PSK=$([[ ${WG_PSK:-} == yes ]] && echo 1 || echo 0)
  OUTPUT=${WG_EXPORT_DIR:-$OUTPUT}
  QR=$([[ ${WG_QR:-} == yes ]] && echo 1 || echo 0)
  DRY_RUN=$([[ ${WG_DRY_RUN:-} == yes ]] && echo 1 || echo 0)
  ARGS=()
  [[ -n ${WG_BACKUP_FILE:-} ]] && ARGS=("$WG_BACKUP_FILE")
  if [[ $CLI_COMMAND == --reconfigure && -n ${WG_MODE:-} ]]; then
    MODE_ARG=$WG_MODE
  fi
  [[ -n $CLIENT ]] && { validate_client || die "Invalid WG_CLIENT '$CLIENT' in preset '$WG_PRESET_FILE'."; }
  return 0
}

cli_apply_flags() {
  [[ -n $CLI_IFACE ]] && IFACE=$CLI_IFACE
  [[ $CLI_YES == 1 ]] && YES=1
  [[ $CLI_DRY_RUN == 1 ]] && DRY_RUN=1
  return 0
}

cli_dispatch() {
  case $CLI_COMMAND in
    --install)
      [[ -n $MODE ]] || die "WG_MODE is required in the preset (hub or full)."
      command_install
      ;;
    --add)
      [[ -n $CLIENT ]] || die "WG_CLIENT is required in the preset for --add."
      command_add
      if [[ -n $OUTPUT ]]; then
        command_export
      fi
      ;;
    --remove)
      [[ -n $CLIENT ]] || die "WG_CLIENT is required in the preset for --remove."
      command_remove
      ;;
    --list)
      command_list
      ;;
    --status)
      command_status
      ;;
    --doctor)
      command_doctor
      ;;
    --backup)
      command_backup
      ;;
    --restore)
      command_restore
      ;;
    --uninstall)
      command_uninstall
      ;;
    --reconfigure)
      command_reconfigure
      ;;
    *)
      return 1
      ;;
  esac
  return 0
}
