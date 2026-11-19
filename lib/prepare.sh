# shellcheck shell=bash
command_prepare() {
  local mode=${1:-check}
  [[ $mode == "install" ]] && require_root
  distro_detect
  printf 'Checking system requirements for %s...\n\n' "$DISTRO"
  check_requirements "$mode"
}