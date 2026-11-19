# shellcheck shell=bash
select_mode() {
  [[ -n $MODE ]] && return 0
  # IFACE is a global variable set by caller
  cat <<EOF
WireGuard setup: select a mode for interface $IFACE
  1) Hub-and-spoke (private network between your devices)
  2) Full-tunnel client VPN (all client traffic goes through this server)
  3) Back
EOF
  read -r -p "Select 1-3: " choice
  case "$choice" in
    1) MODE=hub ;;
    2) MODE=full ;;
    3) die "Installation canceled. No system changes were made." ;;
    *) die "Invalid mode selection '$choice'. Enter 1, 2, or 3." ;;
  esac
}
route_conflict() {
  validate_cidr "$SUBNET"
  local network dest
  network=$(python3 - "$SUBNET" <<'PY'
import ipaddress, sys
network = ipaddress.IPv4Network(sys.argv[1], strict=False)
print(str(network))
PY
  )
  while read -r dest _rest; do
    [[ -n $dest && $dest != "$network" && $dest != default ]] || continue
    if python3 - "$dest" "$network" <<'PY' >/dev/null 2>&1
import ipaddress, sys
a=ipaddress.IPv4Network(sys.argv[1], strict=False)
b=ipaddress.IPv4Network(sys.argv[2], strict=False)
raise SystemExit(0 if a.overlaps(b) else 1)
PY
    then
      die "The tunnel subnet '$network' overlaps existing route '$dest'. Choose another subnet or remove the conflicting route."
    fi
  done < <(ip -4 route show 2>/dev/null | awk '{print $1}')
}
detect_endpoint() {
  [[ -n $ENDPOINT ]] && return 0
  local rc=0
  ENDPOINT=$(curl -4fsS --max-time 5 https://api.ipify.org 2>/dev/null) || rc=$?
  [[ -n $ENDPOINT ]] || die "Could not detect a public endpoint IP (curl exit $rc). Enter the public IP or hostname at the prompt, or install/repair curl and check proxy settings."
  validate_endpoint
  log INFO "Detected public endpoint $ENDPOINT. Verify it in the setup confirmation."
}
dns_addresses() {
  case "$DNS" in
    system)
      awk '/^nameserver / {print $2}' /etc/resolv.conf 2>/dev/null | awk '!seen[$0]++' | paste -sd, -
      ;;
    cloudflare) echo "1.1.1.1,1.0.0.1" ;;
    google) echo "8.8.8.8,8.8.4.4" ;;
    quad9) echo "9.9.9.9,149.112.112.112" ;;
    opendns) echo "208.67.222.222,208.67.220.220" ;;
    *) echo "$DNS" ;;
  esac
}
select_dns() {
  [[ $MODE == full ]] || return 0
  if [[ $DNS == system && $YES == 0 ]]; then
    cat <<'EOF'
Full-tunnel DNS:
  1) System resolver (default)
  2) Cloudflare
  3) Google
  4) Quad9
  5) OpenDNS
  6) Custom
EOF
    read -r -p "Select 1-6: " choice
    case "$choice" in
      1) DNS=system ;;
      2) DNS=cloudflare ;;
      3) DNS=google ;;
      4) DNS=quad9 ;;
      5) DNS=opendns ;;
      6) read -r -p "Enter comma-separated DNS IPv4 addresses: " DNS ;;
      *) die "Invalid DNS selection '$choice'. Enter 1-6." ;;
    esac
  fi
  validate_dns
}
allocate_client_ip() {
  python3 - "$SUBNET" "$ETC_ROOT/$IFACE.conf" <<'PY'
import ipaddress, sys
network = ipaddress.IPv4Network(sys.argv[1], strict=False)
used = set()
try:
    for line in open(sys.argv[2], encoding="utf-8"):
        key, _, val = line.partition("=")
        if key.strip() not in ("Address", "AllowedIPs"):
            continue
        for item in val.split(","):
            try:
                used.add(ipaddress.IPv4Address(item.strip().split("/")[0]))
            except ValueError:
                pass
except FileNotFoundError:
    pass
for addr in network.hosts():
    if addr not in used:
        print(f"{addr}/{network.prefixlen}")
        break
PY
}
generate_psk() {
  if [[ $PSK == 1 ]]; then wg genpsk; else echo ""; fi
}
generate_client_config() {
  local client_ip=$2 client_private=$3 server_public=$4 psk=$5
  local allowed dns_lines=""
  if [[ $MODE == full && $SPLIT_TUNNEL != 1 ]]; then
    allowed="0.0.0.0/0"
  else
    allowed=$SUBNET
    if [[ -n ${ROUTES:-} ]]; then allowed="$allowed, ${ROUTES//,/ ,}"
    fi
  fi
  if [[ $MODE == full || $DNS != system ]]; then
    dns_lines="DNS = $(dns_addresses)"
  fi
  cat <<EOF
[Interface]
Address = $client_ip
PrivateKey = $client_private
MTU = $MTU
$([[ -n $dns_lines ]] && printf '%s\n' "$dns_lines")

[Peer]
PublicKey = $server_public
EOF
  [[ -n $psk ]] && printf 'PresharedKey = %s\n' "$psk"
  cat <<EOF
Endpoint = $ENDPOINT:$PORT
AllowedIPs = $allowed
PersistentKeepalive = $KEEPALIVE
EOF
}
ufw_nat_file() {
  printf '%s/interfaces/%s/ufw-nat.rules\n' "$STATE_ROOT" "$IFACE"
}
ufw_nat_block() {
  local wan=$1
  printf '# BEGIN wg-manager %s\n' "$IFACE"
  printf '*nat\n'
  printf ':POSTROUTING ACCEPT [0:0]\n'
  printf -- '-A POSTROUTING -o %s -j MASQUERADE\n' "$wan"
  printf 'COMMIT\n'
  printf '# END wg-manager %s\n' "$IFACE"
}
ufw_nat_remove_block() {
  local rules_file=$1
  python3 - "$rules_file" "$IFACE" <<'PY' || return 1
import os, sys, tempfile
rules, iface = sys.argv[1:3]
begin = f"# BEGIN wg-manager {iface}"
end = f"# END wg-manager {iface}"
lines = open(rules, encoding="utf-8").read().splitlines(keepends=True)
out, skipping, changed = [], False, False
for line in lines:
    stripped = line.strip()
    if stripped == begin:
        skipping = True
        changed = True
        continue
    if skipping:
        if stripped == end:
            skipping = False
        continue
    out.append(line)
if skipping:
    raise SystemExit(f"unterminated {begin} block in {rules}")
if not changed:
    raise SystemExit(0)
mode = os.stat(rules).st_mode & 0o777
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(rules) or ".")
with os.fdopen(fd, "w", encoding="utf-8") as f:
    f.writelines(out)
os.chmod(tmp, mode)
os.replace(tmp, rules)
PY
}
apply_ufw_nat() {
  local wan=${1:-${WAN:-}} rules_file state tmp
  rules_file=$(ufw_rules_file)
  [[ -n $wan ]] || die "Cannot apply NAT rules for '$IFACE': no WAN interface is recorded."
  state=$(ufw_nat_file)
  if [[ $DRY_RUN == 1 ]]; then
    printf 'Would add NAT rules for %s to %s:\n' "$wan" "$rules_file"
    ufw_nat_block "$wan"
    return 0
  fi
  install -d -m 700 "$(dirname "$state")"
  tmp=$(mktemp "$(dirname "$state")/.ufw-nat.XXXXXX")
  ufw_nat_block "$wan" >"$tmp"
  chmod 600 "$tmp"
  mv -f "$tmp" "$state"
  python3 - "$rules_file" "$IFACE" "$state" <<'PY' || die "Could not update $rules_file for '$IFACE'. Check the file layout and re-run."
import os, sys, tempfile
rules, iface, block_path = sys.argv[1:4]
begin = f"# BEGIN wg-manager {iface}"
end = f"# END wg-manager {iface}"
block = open(block_path, encoding="utf-8").read()
lines = open(rules, encoding="utf-8").read().splitlines(keepends=True)
out, skipping = [], False
for line in lines:
    stripped = line.strip()
    if stripped == begin:
        skipping = True
        continue
    if skipping:
        if stripped == end:
            skipping = False
        continue
    out.append(line)
if skipping:
    raise SystemExit(f"unterminated {begin} block in {rules}")
insert_at = next((i for i, l in enumerate(out) if l.strip() == "*filter"), None)
if insert_at is None:
    raise SystemExit(f"no *filter section in {rules}")
if insert_at > 0 and not out[insert_at - 1].endswith("\n"):
    out[insert_at - 1] += "\n"
out.insert(insert_at, block)
mode = os.stat(rules).st_mode & 0o777
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(rules) or ".")
with os.fdopen(fd, "w", encoding="utf-8") as f:
    f.writelines(out)
os.chmod(tmp, mode)
os.replace(tmp, rules)
PY
  ufw --force reload >/dev/null || die "ufw reload failed after adding NAT rules for '$IFACE'."
  iptables -t nat -S POSTROUTING 2>/dev/null | grep -q -- "-o $wan -j MASQUERADE" ||
    die "NAT rule for '$IFACE' is not active after ufw reload. Inspect $rules_file."
}
remove_ufw_nat() {
  local rules_file state
  rules_file=$(ufw_rules_file)
  state=$(ufw_nat_file)
  if [[ $DRY_RUN == 1 ]]; then
    printf 'Would remove NAT rules for %s from %s\n' "$IFACE" "$rules_file"
    return 0
  fi
  if [[ -f $rules_file ]] && grep -q -- "# BEGIN wg-manager $IFACE" "$rules_file"; then
    ufw_nat_remove_block "$rules_file" || die "Could not remove the NAT block for '$IFACE' from $rules_file."
    ufw --force reload >/dev/null 2>&1 || die "ufw reload failed while removing NAT rules for '$IFACE'."
  fi
  rm -f "$state" "$(metadata_dir)/ufw-masq"
}
add_firewall_rules() {
  local firewall=$1
  case "$firewall" in
    ufw)
      if [[ $DRY_RUN != 1 ]]; then
        ufw allow "$PORT"/udp >/dev/null || die "Could not allow UDP port $PORT in UFW."
      fi
      if [[ $MODE == full ]]; then
        if [[ $DRY_RUN != 1 ]]; then
          ufw route allow in on "$IFACE" out on "$WAN" >/dev/null || die "Could not add the full-tunnel UFW route for '$IFACE'."
        fi
        apply_ufw_nat "$WAN"
      fi
      ;;
    firewalld)
      [[ $DRY_RUN == 1 ]] || {
        firewall-cmd --permanent --add-port="$PORT"/udp >/dev/null
        firewall-cmd --permanent --zone=trusted --add-interface="$IFACE" >/dev/null
        [[ $MODE == full ]] && firewall-cmd --permanent --zone=external --add-interface="$WAN" >/dev/null
        [[ $MODE == full ]] && firewall-cmd --permanent --zone=external --add-masquerade >/dev/null
        firewall-cmd --reload >/dev/null
      }
      ;;
    iptables)
      [[ $DRY_RUN == 1 ]] || {
        iptables -C INPUT -p udp --dport "$PORT" -j ACCEPT 2>/dev/null ||
          iptables -I INPUT -p udp --dport "$PORT" -j ACCEPT
        iptables -C FORWARD -i "$IFACE" -j ACCEPT 2>/dev/null ||
          iptables -I FORWARD -i "$IFACE" -j ACCEPT
        iptables -C FORWARD -o "$IFACE" -j ACCEPT 2>/dev/null ||
          iptables -I FORWARD -o "$IFACE" -j ACCEPT
        if [[ $MODE == full ]]; then
          iptables -t nat -C POSTROUTING -o "$WAN" -j MASQUERADE 2>/dev/null ||
            iptables -t nat -I POSTROUTING -o "$WAN" -j MASQUERADE
        fi
      }
      ;;
  esac
}
remove_full_tunnel_rules() {
  local firewall=$1
  case "$firewall" in
    ufw)
      ufw route delete allow in on "$IFACE" out on "$WAN" >/dev/null 2>&1 ||
        die "Could not remove the full-tunnel UFW route for '$IFACE'."
      remove_ufw_nat
      ;;
    firewalld)
      firewall-cmd --permanent --zone=external --remove-interface="$WAN" >/dev/null ||
        die "Could not remove WAN interface '$WAN' from the firewalld external zone."
      firewall-cmd --permanent --zone=external --remove-masquerade >/dev/null ||
        die "Could not disable firewalld masquerading."
      firewall-cmd --reload >/dev/null || die "Could not reload firewalld after removing full-tunnel rules."
      ;;
    iptables)
      iptables -t nat -D POSTROUTING -o "$WAN" -j MASQUERADE >/dev/null 2>&1 ||
        die "Could not remove the full-tunnel iptables MASQUERADE rule for '$WAN'."
      ;;
    *) die "Unsupported firewall backend '$firewall'." ;;
  esac
}
remove_firewall_rules() {
  local firewall=$1
  case "$firewall" in
    ufw)
      ufw delete allow "$PORT"/udp >/dev/null 2>&1 || die "Could not remove the UFW UDP port rule for '$IFACE'."
      if [[ $MODE == full ]]; then
        ufw route delete allow in on "$IFACE" out on "$WAN" >/dev/null 2>&1 ||
          die "Could not remove the UFW full-tunnel route for '$IFACE'."
      fi
      remove_ufw_nat
      ;;
    firewalld)
      firewall-cmd --permanent --remove-port="$PORT"/udp >/dev/null 2>&1 ||
        die "Could not remove UDP port $PORT from firewalld."
      firewall-cmd --permanent --zone=trusted --remove-interface="$IFACE" >/dev/null 2>&1 ||
        die "Could not remove '$IFACE' from the firewalld trusted zone."
      if [[ $MODE == full ]]; then
        firewall-cmd --permanent --zone=external --remove-interface="$WAN" >/dev/null 2>&1 ||
          die "Could not remove '$WAN' from the firewalld external zone."
        firewall-cmd --permanent --zone=external --remove-masquerade >/dev/null 2>&1 ||
          die "Could not disable firewalld masquerading."
      fi
      firewall-cmd --reload >/dev/null 2>&1 || die "Could not reload firewalld after rule removal."
      ;;
    iptables)
      iptables -D INPUT -p udp --dport "$PORT" -j ACCEPT >/dev/null 2>&1 ||
        die "Could not remove the iptables UDP port rule for '$IFACE'."
      iptables -D FORWARD -i "$IFACE" -j ACCEPT >/dev/null 2>&1 ||
        die "Could not remove the iptables forwarding rule for '$IFACE'."
      iptables -D FORWARD -o "$IFACE" -j ACCEPT >/dev/null 2>&1 ||
        die "Could not remove the iptables forwarding rule for '$IFACE'."
      if [[ $MODE == full ]]; then
        iptables -t nat -D POSTROUTING -o "$WAN" -j MASQUERADE >/dev/null 2>&1 ||
          die "Could not remove the iptables MASQUERADE rule for '$WAN'."
      fi
      ;;
    *) die "Unsupported firewall backend '$firewall'." ;;
  esac
}
enable_forwarding() {
  local file="$SYSCTL_DIR/99-wg-manager-$IFACE.conf"
  if [[ $DRY_RUN == 1 ]]; then
    printf 'Would create %s with net.ipv4.ip_forward=1\n' "$file"
    [[ -n $IPV6 ]] && printf 'Would create IPv6 forwarding entries in %s\n' "$file"
    return
  fi
  {
    echo "net.ipv4.ip_forward=1"
    [[ -n $IPV6 ]] && echo "net.ipv6.conf.all.forwarding=1"
  } >"$file"
  chmod 600 "$file"
  sysctl -w net.ipv4.ip_forward=1 >/dev/null
  [[ -n $IPV6 ]] && sysctl -w net.ipv6.conf.all.forwarding=1 >/dev/null
}
write_server_config() {
  local server_private=$1
  local server_address
  server_address=$(python3 - "$SUBNET" <<'PY'
import ipaddress, sys
network=ipaddress.IPv4Network(sys.argv[1], strict=False)
print(f"{next(network.hosts())}/{network.prefixlen}")
PY
)
  cat >"$ETC_ROOT/$IFACE.conf" <<EOF
[Interface]
Address = $server_address
PrivateKey = $server_private
ListenPort = $PORT
MTU = $MTU
EOF
  [[ -n $IPV6 ]] && sed -i "1a Address = $IPV6" "$ETC_ROOT/$IFACE.conf"
  chmod 600 "$ETC_ROOT/$IFACE.conf"
}
install_service() {
  local change
  change=$1
  if [[ $DRY_RUN == 1 ]]; then
    printf 'Would %s the %s service for %s\n' "$change" "$SERVICE_BACKEND" "$IFACE"
    return
  fi
  if [[ $SERVICE_BACKEND == systemd ]]; then
    if [[ $change == start ]]; then
      systemctl enable --now "wg-quick@$IFACE" >/dev/null
    else
      systemctl disable --now "wg-quick@$IFACE" >/dev/null 2>&1 || true
      rm -f "$UNIT_DIR/wg-manager-$IFACE.service"
    fi
  elif [[ $SERVICE_BACKEND == openrc ]]; then
    if [[ $change == start ]]; then
      rc-update add "wg-quick.$IFACE" default >/dev/null 2>&1 || true
      rc-service "wg-quick.$IFACE" start >/dev/null 2>&1 ||
        die "The WireGuard interface '$IFACE' could not start. Inspect 'rc-service wg-quick.$IFACE start' and fix the underlying error."
    else
      rc-service "wg-quick.$IFACE" stop >/dev/null 2>&1 || true
      rc-update del "wg-quick.$IFACE" default >/dev/null 2>&1 || true
    fi
  else
    if [[ $change == start ]]; then
      wg-quick up "$IFACE" || die "Could not start interface '$IFACE'. Run 'wg-quick up $IFACE' to inspect the error."
    else
      wg-quick down "$IFACE" >/dev/null 2>&1 || true
    fi
  fi
}
