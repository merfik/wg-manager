# shellcheck shell=bash
command_reconfigure() {
  require_root
  validate_iface
  local new_mode=$MODE_ARG
  read_metadata
  [[ $MODE == hub || $MODE == full ]] || die "Stored mode for '$IFACE' is missing or invalid. Reinstall '$IFACE' to repair metadata."
  [[ $new_mode =~ ^(hub|full)$ ]] || die "Reconfigure requires --mode hub or --mode full."
  local old=$MODE new=$new_mode
  [[ $old != "$new" ]] || { printf 'Interface %s is already in %s mode. No changes needed.\n' "$IFACE" "$new"; return 0; }
  printf 'Reconfigure %s: %s -> %s\n' "$IFACE" "$old" "$new"
  printf '  Config AllowedIPs:\n'
  printf '    before: %s\n' "$([[ $old == full ]] && echo '0.0.0.0/0, ::/0' || echo "$SUBNET")"
  printf '    after:  %s\n' "$([[ $new == full ]] && echo '0.0.0.0/0, ::/0' || echo "$SUBNET")"
  printf '  MASQUERADE: %s -> %s\n' "$([[ $old == full ]] && echo present || echo absent)" "$([[ $new == full ]] && echo present || echo absent)"
  if [[ $DRY_RUN == 1 ]]; then
    printf 'Dry run: no changes made.\n'
    return 0
  fi
  if [[ $YES != 1 ]] && ! confirm "Apply this reconfiguration?"; then
    log INFO "Reconfiguration canceled. No changes were made."
    return 0
  fi
  MODE=$new
  if [[ $new == full ]]; then
    WAN=$(detect_wan)
    [[ -n $WAN ]] || die "Could not detect a WAN interface. Check the default route and re-run."
    if [[ $YES != 1 ]] && ! confirm "Use WAN interface '$WAN'?"; then
      log INFO "Reconfiguration canceled because the WAN interface was not confirmed."
      return 0
    fi
  fi
  add_firewall_rules "$FIREWALL"
  if [[ $old == full && $new == hub ]]; then remove_firewall_rules "$FIREWALL"; fi
  while read -r client; do
    [[ -n $client ]] || continue
    local file="$STATE_ROOT/clients/$IFACE/$client.conf"
    local allowed
    if [[ $new == full ]]; then
      allowed='0.0.0.0/0, ::/0'
    else
      allowed=$SUBNET
    fi
    sed -i -E "s|^AllowedIPs = .*|AllowedIPs = $allowed|" "$file"
  done < <(find "$STATE_ROOT/clients/$IFACE" -name '*.conf' -printf '%f\n' 2>/dev/null | sed 's/.conf$//' )
  write_metadata
  install_service start
  log INFO "Reconfigured $IFACE from $old to $new mode."
}
command_backup() {
  require_root
  validate_iface
  read_metadata
  local output=${OUTPUT:-"$IFACE-backup-$(date -u +%Y%m%dT%H%M%SZ).tar.gz"}
  [[ $output == *.tar.gz ]] || output="$output.tar.gz"
  local parent=${output%/*}
  [[ $parent == "$output" ]] && parent=.
  if [[ $DRY_RUN == 1 ]]; then
    printf 'Dry run: would back up %s to %s\n' "$IFACE" "$output"
    return
  fi
  mkdir -p "$parent"
  tar -C / -czf "$output" \
    "${ETC_ROOT#/}/$IFACE.conf" \
    "${STATE_ROOT#/}/interfaces/$IFACE" \
    "${STATE_ROOT#/}/clients/$IFACE" \
    "${SYSCTL_DIR#/}/99-wg-manager-$IFACE.conf" 2>/dev/null ||
    die "Backup creation failed for '$IFACE'. Check the output path '$output' and available disk space."
  chmod 600 "$output"
  sha256sum "$output"
  printf 'Backup: %s\n' "$output"
}
command_restore() {
  require_root
  [[ ${#ARGS[@]} -ge 1 ]] || die "Restore requires a backup file."
  local file=${ARGS[0]}
  [[ -f $file ]] || die "Backup file '$file' does not exist. Check the path and re-run."
  if [[ $DRY_RUN == 1 ]]; then
    printf 'Dry run: would validate and restore backup %s\n' "$file"
    return
  fi
  if [[ $YES != 1 ]] && ! confirm "Restore WireGuard backup '$file'? This may replace managed files."; then
    log INFO "Restore canceled. No changes were made."
    return 0
  fi
  tar -tzf "$file" >/dev/null 2>&1 || die "Backup '$file' is not a valid gzip tar archive. Create a new backup and re-run."
  local metadata_file
  metadata_file=$(tar -tzf "$file" | grep '/metadata$' | head -n1)
  [[ -n $metadata_file ]] || die "Backup '$file' has no usable interface metadata. Restore it only after reviewing the archive."
  IFACE=$(printf '%s' "$metadata_file" | sed -E 's|.*/interfaces/([^/]+)/metadata|\1|')
  tar -xzf "$file" -C /
  read_metadata
  enable_forwarding
  add_firewall_rules "$FIREWALL"
  install_service start
  log INFO "Restored WireGuard backup '$file' for '$IFACE'."
}
command_uninstall() {
  UNINSTALL_SUCCEEDED=0
  require_root
  validate_iface
  if [[ ! -f $(metadata_file) ]]; then
    die "Interface '$IFACE' is not managed by wg-manager. Run 'wg-manager list' to find managed interfaces."
  fi
  read_metadata
  if [[ $DRY_RUN == 1 ]]; then
    printf 'Dry run: would uninstall %s and remove:\n' "$IFACE"
    printf '  interface and service\n'
      printf '  %s\n' "$ETC_ROOT/$IFACE.conf"
    printf '  firewall rules, MASQUERADE, and sysctl file\n'
    printf '  managed keys, peers, and metadata\n'
    return
  fi
  if [[ $YES != 1 ]] && ! confirm "Uninstall interface '$IFACE' and remove all of its keys and configs?"; then
    log INFO "Uninstall canceled. No changes were made."
    return 0
  fi
  install_service stop
  remove_firewall_rules "$FIREWALL"
  rm -f "$ETC_ROOT/$IFACE.conf" "$SYSCTL_DIR/99-wg-manager-$IFACE.conf"
  rm -rf "$(metadata_dir)" "$STATE_ROOT/clients/$IFACE"
  log INFO "Uninstalled $IFACE and removed its managed files and firewall rules."
  export UNINSTALL_SUCCEEDED=1
}
