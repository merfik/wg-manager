#!/usr/bin/env bats

setup() {
  export WG_MANAGER_STATE_ROOT="$BATS_TEST_TMPDIR/state"
  export WG_MANAGER_ETC_ROOT="$BATS_TEST_TMPDIR/etc"
  export WG_MANAGER_SYSCTL_DIR="$BATS_TEST_TMPDIR/sysctl"
  source "$BATS_TEST_DIRNAME/../wg-manager.sh"
  IFACE=wg0
  MODE=hub
}

@test "alpha minimal" {
  true
}

@test "beta locals and mkdir" {
  local stage="$BATS_TEST_TMPDIR/good"
  mkdir -p "$stage/${WG_MANAGER_STATE_ROOT#/}/interfaces/wg0" "$stage/${WG_MANAGER_ETC_ROOT#/}" "$stage/${WG_MANAGER_SYSCTL_DIR#/}"
  printf 'MODE=hub\nIFACE=wg0\n' >"$stage/${WG_MANAGER_STATE_ROOT#/}/interfaces/wg0/metadata"
}

@test "gamma tar continuation" {
  local stage="$BATS_TEST_TMPDIR/good2"
  mkdir -p "$stage"
  printf 'x\n' >"$stage/a"
  tar -czf "$BATS_TEST_TMPDIR/good.tar.gz" -C "$stage" \
    "a"
}

@test "delta command call" {
  require_root() { return 0; }
  enable_forwarding() { :; }
  add_firewall_rules() { :; }
  install_service() { :; }
  local stage="$BATS_TEST_TMPDIR/good3"
  mkdir -p "$stage/${WG_MANAGER_STATE_ROOT#/}/interfaces/wg0" "$stage/${WG_MANAGER_ETC_ROOT#/}" "$stage/${WG_MANAGER_SYSCTL_DIR#/}"
  printf 'MODE=hub\nIFACE=wg0\nSUBNET=10.7.0.0/24\nIPV6=\nPORT=51820\nENDPOINT=192.0.2.10\nDNS=system\nMTU=1420\nKEEPALIVE=25\nWAN=eth0\nFIREWALL=iptables\nSERVICE_BACKEND=systemd\nSPLIT_TUNNEL=0\nROUTES=\nPSK=0\nCREATED_AT=2026-01-01T00:00:00Z\n' >"$stage/${WG_MANAGER_STATE_ROOT#/}/interfaces/wg0/metadata"
  printf '[Interface]\nAddress = 10.7.0.1/24\nPrivateKey = k\nListenPort = 51820\n' >"$stage/${WG_MANAGER_ETC_ROOT#/}/wg0.conf"
  printf 'net.ipv4.ip_forward=1\n' >"$stage/${WG_MANAGER_SYSCTL_DIR#/}/99-wg-manager-wg0.conf"
  tar -czf "$BATS_TEST_TMPDIR/good.tar.gz" -C "$stage" \
    "${WG_MANAGER_STATE_ROOT#/}/interfaces/wg0/metadata" \
    "${WG_MANAGER_ETC_ROOT#/}/wg0.conf" \
    "${WG_MANAGER_SYSCTL_DIR#/}/99-wg-manager-wg0.conf"
  ARGS=("$BATS_TEST_TMPDIR/good.tar.gz")
  YES=1
  MODE=
  SUBNET=
  command_restore
  [ "$MODE" = hub ]
  [ "$SUBNET" = 10.7.0.0/24 ]
}
