# shellcheck shell=bash
command_install() {
  INSTALL_SUCCEEDED=0
  require_root
  distro_detect
  validate_iface
  if [[ -e "$ETC_ROOT/$IFACE.conf" || -e "$(metadata_dir)" || -e "$STATE_ROOT/clients/$IFACE" ]]; then
    die "Interface '$IFACE' already has WireGuard or manager state. Choose another interface or manage the existing one."
  fi
  validate_port
  validate_mtu
  validate_keepalive
  validate_ipv6
  validate_endpoint
  validate_dns
  select_mode
  [[ $MODE =~ ^(hub|full)$ ]] || die "Invalid mode '$MODE'. Use --mode hub or --mode full."
  route_conflict
  if [[ $MODE == full ]]; then
    WAN=$(detect_wan)
    [[ -n $WAN ]] || die "No WAN interface was detected from the default route. Set an interface with route configuration or use --iface for the tunnel; WAN discovery requires network access."
    [[ -e "/sys/class/net/$WAN" ]] || die "Detected WAN interface '$WAN' is unavailable. Verify network configuration and re-run."
    if [[ $YES != 1 ]] && ! confirm "Use WAN interface '$WAN'?"; then
      log INFO "Installation canceled because the WAN interface was not confirmed."
      return 0
    fi
    select_dns
  fi
  if [[ -n $ENDPOINT && $ENDPOINT =~ [A-Za-z] ]]; then
    log INFO "Using hostname endpoint '$ENDPOINT'; consider a DDNS hostname if it changes."
  fi
  if [[ -z $ENDPOINT ]]; then detect_endpoint; fi
  [[ -n $ENDPOINT ]] || die "An endpoint is required. Supply --endpoint <public-IP-or-hostname>."
  validate_endpoint

  if ! command -v wg >/dev/null 2>&1 || ! command -v wg-quick >/dev/null 2>&1; then
    die "Missing WireGuard tools. Install 'wireguard-tools' and the WireGuard kernel module for $DISTRO, then re-run. On systems without kernel support, install wireguard-go if available."
  fi
  FIREWALL=$(detect_firewall)
  [[ $FIREWALL != none ]] || die "No supported firewall backend is active or installed. Install and configure UFW, firewalld, or iptables, then re-run."

  if [[ $DRY_RUN == 1 ]]; then
    printf 'Dry run: would install interface %s\n' "$IFACE"
    printf '  mode: %s, subnet: %s, port: %s, mtu: %s\n' "$MODE" "$SUBNET" "$PORT" "$MTU"
    [[ -n ${WAN:-} ]] && printf '  WAN: %s, DNS: %s\n' "$WAN" "$(dns_addresses)"
    printf '  firewall: %s\n' "$FIREWALL"
    enable_forwarding
    add_firewall_rules "$FIREWALL"
    return 0
  fi

  ensure_state_dirs
  write_metadata
  local server_private server_public
  server_private=$(wg genkey)
  server_public=$(printf '%s' "$server_private" | wg pubkey)
  write_server_config "$server_private"
  chmod 600 "$ETC_ROOT/$IFACE.conf"
  printf '%s\n' "$server_private" >"$STATE_ROOT/interfaces/$IFACE/server-private.key"
  printf '%s\n' "$server_public" >"$STATE_ROOT/interfaces/$IFACE/server-public.key"
  chmod 600 "$STATE_ROOT/interfaces/$IFACE/"*.key
  enable_forwarding
  add_firewall_rules "$FIREWALL"
  if ! install_service start; then
    rm -f "$ETC_ROOT/$IFACE.conf" "$STATE_ROOT/interfaces/$IFACE/server-private.key" "$STATE_ROOT/interfaces/$IFACE/server-public.key"
    rm -rf "$(metadata_dir)" "$STATE_ROOT/clients/$IFACE"
    remove_firewall_rules "$FIREWALL"
    rm -f "$SYSCTL_DIR/99-wg-manager-$IFACE.conf"
    die "Interface '$IFACE' failed to start and partial changes were rolled back. Run 'wg-manager doctor --iface $IFACE' after fixing the underlying service error."
  fi
  write_metadata
  log INFO "Installed $IFACE in $MODE mode."
  export INSTALL_SUCCEEDED=1
}
