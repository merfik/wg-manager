# shellcheck shell=bash
command_add() {
  require_root
  distro_detect
  validate_iface
  read_metadata
  validate_mtu
  validate_keepalive
  local client_dir="$STATE_ROOT/clients/$IFACE"
  local private public psk="" client_ip config
  [[ -f "$client_dir/$CLIENT.private" ]] && die "Client '$CLIENT' already exists. Remove it before adding it again."
  private=$(wg genkey)
  public=$(printf '%s' "$private" | wg pubkey)
  psk=$(generate_psk)
  client_ip=$(allocate_client_ip)
  [[ -n $client_ip ]] || die "No tunnel addresses remain in '$SUBNET'. Expand --subnet with a larger CIDR or remove a client."
  config="$client_dir/$CLIENT.conf"
  generate_client_config "$CLIENT" "$client_ip" "$private" "$(cat "$STATE_ROOT/interfaces/$IFACE/server-public.key")" "$psk" >"$config"
  chmod 600 "$config"
  printf '%s\n' "$private" >"$client_dir/$CLIENT.private"
  printf '%s\n' "$public" >"$client_dir/$CLIENT.public"
  [[ -n $psk ]] && printf '%s\n' "$psk" >"$client_dir/$CLIENT.psk"
  chmod 600 "$client_dir/$CLIENT.private" "$client_dir/$CLIENT.public"
  [[ -n $psk ]] && chmod 600 "$client_dir/$CLIENT.psk"
  {
    echo "[Peer]"
    echo "# $CLIENT"
    echo "PublicKey = $public"
    [[ -n $psk ]] && echo "PresharedKey = $psk"
    echo "AllowedIPs = $client_ip"
  } >>"$ETC_ROOT/$IFACE.conf"
  chmod 600 "$ETC_ROOT/$IFACE.conf"
  if command -v wg >/dev/null 2>&1; then
    wg-quick strip "$IFACE" >/tmp/wg-strip-"$IFACE".conf 2>/dev/null
    wg syncconf "$IFACE" </tmp/wg-strip-"$IFACE".conf 2>/dev/null || true
    rm -f /tmp/wg-strip-"$IFACE".conf
  fi
  log INFO "Added client '$CLIENT'. Its private config is at $config."
  printf '%s\n' "$config"
}
command_remove() {
  require_root
  distro_detect
  validate_iface
  read_metadata
  local client_dir="$STATE_ROOT/clients/$IFACE"
  local public="$client_dir/$CLIENT.public"
  [[ -f $public ]] || die "Client '$CLIENT' is not present on interface '$IFACE'. Run 'wg-manager list --iface $IFACE'."
  if [[ $YES != 1 ]] && ! confirm "Remove client '$CLIENT' from '$IFACE'?"; then
    log INFO "Removal canceled. No changes were made."
    return 0
  fi
  if [[ $DRY_RUN == 1 ]]; then
    printf 'Dry run: would remove client %s and its peer/config files\n' "$CLIENT"
    return
  fi
  local key
  key=$(cat "$public")
  python3 - "$ETC_ROOT/$IFACE.conf" "$key" <<'PY'
import sys
path, key = sys.argv[1:3]
text = open(path, encoding="utf-8").read()
blocks = text.split("\n[Peer]")
kept = [blocks[0]]
for block in blocks[1:]:
    full = "[Peer]" + block
    if f"PublicKey = {key}" not in full:
        kept.append(full)
open(path, "w", encoding="utf-8").write("\n".join([kept[0]] + kept[1:]))
PY
  chmod 600 "$ETC_ROOT/$IFACE.conf"
  rm -f "$client_dir/$CLIENT".*
  wg set "$IFACE" peer "$key" remove 2>/dev/null || true
  wg-quick strip "$IFACE" >/tmp/wg-strip-"$IFACE".conf 2>/dev/null
  wg syncconf "$IFACE" </tmp/wg-strip-"$IFACE".conf 2>/dev/null || true
  rm -f /tmp/wg-strip-"$IFACE".conf
  log INFO "Removed client '$CLIENT' from '$IFACE'."
}
command_list() {
  validate_iface
  read_metadata
  printf 'Interface: %s  Mode: %s  Subnet: %s\n' "$IFACE" "$MODE" "$SUBNET"
  printf 'Clients:\n'
  local client_dir="$STATE_ROOT/clients/$IFACE"
  shopt -s nullglob
  local file name
  for file in "$client_dir"/*.conf; do
    name=${file##*/}
    name=${name%.conf}
    printf '  %s\n' "$name"
  done
}
command_show() {
  validate_iface
  read_metadata
  local file="$STATE_ROOT/clients/$IFACE/$CLIENT.conf"
  [[ -f $file ]] || die "Client '$CLIENT' has no config on interface '$IFACE'. Run 'wg-manager list --iface $IFACE'."
  log INFO "Private key warning: the following config is secret. Do not share screenshots or QR codes."
  cat "$file"
  if [[ ${QR:-0} == 1 ]]; then
    command -v qrencode >/dev/null 2>&1 || die "QR output is required but qrencode is missing. Install qrencode and re-run, or run 'show' without --qr."
    qrencode -t ansiutf8 <"$file"
  fi
}
command_export() {
  validate_iface
  read_metadata
  local source="$STATE_ROOT/clients/$IFACE/$CLIENT.conf"
  [[ -f $source ]] || die "Client '$CLIENT' has no config on interface '$IFACE'."
  local dir=${OUTPUT:-.}
  [[ -d $dir ]] || mkdir -p "$dir"
  install -m 600 "$source" "$dir/$CLIENT.conf"
  if command -v qrencode >/dev/null 2>&1; then
    qrencode -o "$dir/$CLIENT.png" -t PNG <"$source"
    chmod 600 "$dir/$CLIENT.png"
  else
    log ERROR "qrencode is missing, so only the config file was exported. Install qrencode and re-run to export the PNG."
  fi
  log INFO "Exported secret files to $dir/$CLIENT.conf and $dir/$CLIENT.png if qrencode was available."
}
