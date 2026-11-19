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
  local network
  network=$(python3 - "$SUBNET" <<'PY'
import ipaddress, sys
network = ipaddress.IPv4Network(sys.argv[1], strict=False)
print(str(network))
PY
  )
  while read -r route iface rest; do
    [[ -n ${route:-} && $route != "$network" ]] || continue
    if python3 - "$route" "$network" <<'PY' >/dev/null 2>&1
import ipaddress, sys
a=ipaddress.IPv4Network(sys.argv[1], strict=False)
b=ipaddress.IPv4Network(sys.argv[2], strict=False)
raise SystemExit(0 if a.overlaps(b) else 1)
PY
    then
      die "The tunnel subnet '$network' overlaps existing route '$route' on '$iface'. Choose another --subnet or remove the conflicting route."
    fi
  done < <(ip -4 route show 2>/dev/null | awk '{print $1 " " $3}')
}
detect_endpoint() {
  [[ -n $ENDPOINT ]] && return 0
  ENDPOINT=$(curl -4fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)
  [[ -n $ENDPOINT ]] || die "Could not detect a public endpoint IP. Set --endpoint to a public hostname or IP."
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
network=ipaddress.IPv4Network(sys.argv[1], strict=False)
used=set()
path=sys.argv[2]
try:
    for line in open(path, encoding="utf-8"):
        line=line.strip()
        if line.startswith("Address="):
            used.add(ipaddress.IPv4Address(line.split("=",1)[1].split("/",1)[0]))
except FileNotFoundError:
    pass
for addr in network.hosts():
    if addr != network.network_address and addr not in used:
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
    allowed="0.0.0.0/0, ::/0"
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
add_firewall_rules() {
  local firewall=$1
  case "$firewall" in
    ufw)
      [[ $DRY_RUN == 1 ]] || ufw allow "$PORT"/udp >/dev/null
      if [[ $MODE == full ]]; then
        [[ $DRY_RUN == 1 ]] || {
          ufw route allow in on "$IFACE" out on "$WAN" >/dev/null
          python3 - "$WAN" "$STATE_ROOT/interfaces/$IFACE/ufw-masq" <<'PY'
import sys
from pathlib import Path
wan=sys.argv[1]; state=Path(sys.argv[2])
text=f"*nat\n-A POSTROUTING -o {wan} -j MASQUERADE\nCOMMIT\n"
state.write_text(text)
PY
        }
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
remove_firewall_rules() {
  local firewall=$1
  case "$firewall" in
    ufw)
      ufw delete allow "$PORT"/udp >/dev/null 2>&1 || true
      ufw route delete allow in on "$IFACE" out on "$WAN" >/dev/null 2>&1 || true
      ;;
    firewalld)
      firewall-cmd --permanent --remove-port="$PORT"/udp >/dev/null 2>&1 || true
      firewall-cmd --permanent --zone=trusted --remove-interface="$IFACE" >/dev/null 2>&1 || true
      firewall-cmd --permanent --zone=external --remove-interface="$WAN" >/dev/null 2>&1 || true
      firewall-cmd --permanent --zone=external --remove-masquerade >/dev/null 2>&1 || true
      firewall-cmd --reload >/dev/null 2>&1 || true
      ;;
    iptables)
      iptables -D INPUT -p udp --dport "$PORT" -j ACCEPT >/dev/null 2>&1 || true
      iptables -D FORWARD -i "$IFACE" -j ACCEPT >/dev/null 2>&1 || true
      iptables -D FORWARD -o "$IFACE" -j ACCEPT >/dev/null 2>&1 || true
      iptables -t nat -D POSTROUTING -o "$WAN" -j MASQUERADE >/dev/null 2>&1 || true
      ;;
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
