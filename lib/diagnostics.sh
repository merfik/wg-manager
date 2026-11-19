# shellcheck shell=bash
command_status() {
  validate_iface
  read_metadata
  if ! ip link show "$IFACE" >/dev/null 2>&1; then
    log ERROR "Interface '$IFACE' is not currently present. Start it with 'systemctl start wg-quick@$IFACE' or 'rc-service wg-quick.$IFACE start', then re-run."
    return 1
  fi
  if ! wg show "$IFACE" 2>/dev/null; then
    log ERROR "Could not read WireGuard status for '$IFACE'. Verify permissions and service state."
    return 1
  fi
}
command_doctor() {
  distro_detect
  validate_iface
  read_metadata
  local fail=0
  printf 'Doctor report for %s (%s mode)\n' "$IFACE" "$MODE"
  if command -v wg >/dev/null 2>&1; then
    printf '  [ok] wireguard-tools is installed\n'
  else
    printf '  [FAIL] wireguard-tools missing: install wireguard-tools and the kernel module for %s\n' "$DISTRO"
    fail=1
  fi
  if ip link show "$IFACE" >/dev/null 2>&1; then
    printf '  [ok] interface is present\n'
  else
    printf '  [FAIL] interface is down: start wg-quick@%s or rc-service wg-quick.%s\n' "$IFACE" "$IFACE"
    fail=1
  fi
  if [[ $(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null || echo 0) == 1 ]]; then
    printf '  [ok] IPv4 forwarding is enabled\n'
  else
    printf '  [FAIL] IPv4 forwarding is disabled: enable it through %s/99-wg-manager-%s.conf\n' "$SYSCTL_DIR" "$IFACE"
    fail=1
  fi
  if [[ -n $IPV6 ]]; then
    if [[ $(cat /proc/sys/net/ipv6/conf/all/forwarding 2>/dev/null || echo 0) == 1 ]]; then
      printf '  [ok] IPv6 forwarding is enabled\n'
    else
      printf '  [FAIL] IPv6 forwarding is disabled: enable net.ipv6.conf.all.forwarding\n'
      fail=1
    fi
  fi
  if ss -lun 2>/dev/null | awk '{print $5}' | grep -q ":$PORT$"; then
    printf '  [ok] UDP port %s is listening\n' "$PORT"
  else
    printf '  [FAIL] UDP port %s is not listening: check the firewall and service logs\n' "$PORT"
    fail=1
  fi
  printf '  [info] active firewall backend: %s\n' "$(detect_firewall)"
  if [[ $MODE == full ]]; then
    printf '  [info] IPv6 traffic is not routed through this IPv4-only full tunnel\n'
  fi
  local -a dupes=() non32=()
  local peer_entry host
  local -A seen=()
  while IFS= read -r peer_entry; do
    [[ -n $peer_entry ]] || continue
    host=${peer_entry%%/*}
    if [[ -n ${seen[$host]:-} ]]; then
      dupes+=("$host")
    else
      seen[$host]=1
    fi
    [[ ${peer_entry#*/} == 32 ]] || non32+=("$peer_entry")
  done < <(awk '/^[[:space:]]*\[Peer\]/{p=1;next} /^[[:space:]]*\[/{p=0} p && /^[[:space:]]*AllowedIPs[[:space:]]*=/{split($0,a,"="); n=split(a[2],b,","); for(i=1;i<=n;i++){gsub(/[[:space:]]/,"",b[i]); print b[i]}}' "$ETC_ROOT/$IFACE.conf" 2>/dev/null)
  if ((${#dupes[@]} > 0)); then
    printf '  [FAIL] clients share tunnel address %s: remove and re-add the affected clients\n' "${dupes[*]}"
    fail=1
  fi
  if ((${#non32[@]} > 0)); then
    printf '  [FAIL] peer AllowedIPs %s must be /32: remove and re-add the affected clients\n' "${non32[*]}"
    fail=1
  fi
  if [[ $MODE == full ]]; then
    case $(detect_firewall) in
      ufw)
        if grep -q -- "# BEGIN wg-manager $IFACE" "$(ufw_rules_file)" 2>/dev/null &&
          iptables -t nat -S POSTROUTING 2>/dev/null | grep -q -- "-o $WAN -j MASQUERADE"; then
          printf '  [ok] full-tunnel NAT rule is present in %s\n' "$(ufw_rules_file)"
        else
          printf '  [FAIL] full-tunnel NAT rule is missing: rerun reconfigure --mode full or review %s\n' "$(ufw_rules_file)"
          fail=1
        fi
        ;;
      firewalld)
        if firewall-cmd --zone=external --query-masquerade >/dev/null 2>&1; then
          printf '  [ok] full-tunnel masquerade is enabled for the external zone\n'
        else
          printf '  [FAIL] full-tunnel masquerade is not enabled: rerun reconfigure --mode full or review firewalld\n'
          fail=1
        fi
        ;;
      *)
        if iptables -t nat -S POSTROUTING 2>/dev/null | grep -q "MASQUERADE.*-o $WAN"; then
          printf '  [ok] full-tunnel MASQUERADE rule is present\n'
        else
          printf '  [WARN] MASQUERADE rule not found: rerun reconfigure --mode full or review firewall setup\n'
          fail=1
        fi
        ;;
    esac
  fi
  if getent hosts example.com >/dev/null 2>&1; then
    printf '  [ok] DNS resolution works\n'
  else
    printf '  [FAIL] DNS resolution failed: check /etc/resolv.conf or the selected DNS provider\n'
    fail=1
  fi
  (( fail == 0 )) || return 1
}
