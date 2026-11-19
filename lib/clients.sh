# shellcheck shell=bash
sync_interface_config() {
  local tmp=$1
  if ! ip link show "$IFACE" >/dev/null 2>&1; then
    log INFO "Interface '$IFACE' is not running; the change applies the next time it starts."
    return 0
  fi
  if ! wg-quick strip "$IFACE" >"$tmp/stripped.conf" 2>"$tmp/strip.err"; then
    log ERROR "Could not read the stripped config for '$IFACE': $(cat "$tmp/strip.err")"
    return 1
  fi
  if ! wg syncconf "$IFACE" "$tmp/stripped.conf" 2>"$tmp/sync.err"; then
    log ERROR "wg syncconf failed for '$IFACE': $(cat "$tmp/sync.err")"
    return 1
  fi
}
command_add() {
  require_root
  distro_detect
  validate_iface
  validate_client
  read_metadata
  validate_mtu
  validate_keepalive
  local client_dir="$STATE_ROOT/clients/$IFACE"
  local private public psk="" client_ip host_ip config tmp
  [[ -f "$client_dir/$CLIENT.private" ]] && die "Client '$CLIENT' already exists. Remove it before adding it again."
  private=$(wg genkey)
  public=$(printf '%s' "$private" | wg pubkey)
  psk=$(generate_psk)
  client_ip=$(allocate_client_ip)
  [[ -n $client_ip ]] || die "No tunnel addresses remain in '$SUBNET'. Expand --subnet with a larger CIDR or remove a client."
  [[ $client_ip == */* ]] || die "allocate_client_ip returned '$client_ip' for client '$CLIENT'."
  host_ip=${client_ip%/*}
  config="$client_dir/$CLIENT.conf"
  tmp=$(mktemp -d "$STATE_ROOT/interfaces/$IFACE/.sync.XXXXXX")
  generate_client_config "$CLIENT" "$client_ip" "$private" "$(cat "$STATE_ROOT/interfaces/$IFACE/server-public.key")" "$psk" >"$tmp/client.conf"
  chmod 600 "$tmp/client.conf"
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
    echo "AllowedIPs = $host_ip/32"
  } >"$tmp/peer.conf"
  cp -p "$ETC_ROOT/$IFACE.conf" "$tmp/prev.conf"
  cat "$tmp/peer.conf" >>"$ETC_ROOT/$IFACE.conf"
  chmod 600 "$ETC_ROOT/$IFACE.conf"
  if ! sync_interface_config "$tmp"; then
    cp -p "$tmp/prev.conf" "$ETC_ROOT/$IFACE.conf"
    rm -f "$client_dir/$CLIENT".*
    sync_interface_config "$tmp" >/dev/null 2>&1 || true
    rm -rf "$tmp"
    die "Applying client '$CLIENT' to interface '$IFACE' failed; the server config was rolled back. Run 'wg-manager doctor --iface $IFACE' for details."
  fi
  install -m 600 "$tmp/client.conf" "$config"
  rm -rf "$tmp"
  log INFO "Added client '$CLIENT'. Its private config is at $config."
  printf '%s\n' "$config"
}
command_remove() {
  require_root
  distro_detect
  validate_iface
  validate_client
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
  local key tmp
  key=$(cat "$public")
  tmp=$(mktemp -d "$STATE_ROOT/interfaces/$IFACE/.sync.XXXXXX")
  cp -p "$ETC_ROOT/$IFACE.conf" "$tmp/prev.conf"
  python3 - "$tmp/prev.conf" "$key" "$tmp/new.conf" <<'PY' || { rm -rf "$tmp"; die "Could not rewrite the server config for '$IFACE'."; }
import sys
src, key, dst = sys.argv[1:4]
with open(src, encoding="utf-8", newline="") as f:
    lines = f.readlines()
header, blocks, current = [], [], None
for line in lines:
    if line.strip() == "[Peer]":
        if current is not None:
            blocks.append(current)
        current = [line]
    elif current is None:
        header.append(line)
    else:
        current.append(line)
if current is not None:
    blocks.append(current)
def peer_key(block):
    for line in block:
        stripped = line.strip()
        if stripped.lower().startswith("publickey"):
            return stripped.split("=", 1)[1].strip() if "=" in stripped else ""
    return ""
kept = [b for b in blocks if peer_key(b) != key]
if len(kept) == len(blocks):
    raise SystemExit(f"public key {key} not found in {src}")
with open(dst, "w", encoding="utf-8", newline="") as f:
    f.writelines(header)
    for b in kept:
        f.writelines(b)
PY
  install -m 600 "$tmp/new.conf" "$ETC_ROOT/$IFACE.conf"
  if ! sync_interface_config "$tmp"; then
    cp -p "$tmp/prev.conf" "$ETC_ROOT/$IFACE.conf"
    sync_interface_config "$tmp" >/dev/null 2>&1 || true
    rm -rf "$tmp"
    die "Removing client '$CLIENT' from '$IFACE' failed; the server config was rolled back. Run 'wg-manager doctor --iface $IFACE' for details."
  fi
  rm -f "$client_dir/$CLIENT".*
  rm -rf "$tmp"
  log INFO "Removed client '$CLIENT' from '$IFACE'."
}
command_list() {
  validate_iface
  read_metadata
  printf 'Interface: %s  Mode: %s  Subnet: %s\n' "$IFACE" "$MODE" "$SUBNET"
  printf 'Clients:\n'
  local client_dir="$STATE_ROOT/clients/$IFACE"
  local saved_nullglob
  saved_nullglob=$(shopt -p nullglob)
  shopt -s nullglob
  local file name
  for file in "$client_dir"/*.conf; do
    name=${file##*/}
    name=${name%.conf}
    printf '  %s\n' "$name"
  done
  eval "$saved_nullglob"
}
command_show() {
  validate_iface
  validate_client
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
  validate_client
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
