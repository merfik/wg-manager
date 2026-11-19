#!/usr/bin/bash
set -euo pipefail

WG_MANAGER_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
readonly WG_MANAGER_ROOT

# shellcheck source=lib/common.sh
source "$WG_MANAGER_ROOT/lib/common.sh"
# shellcheck source=lib/network.sh
source "$WG_MANAGER_ROOT/lib/network.sh"
# shellcheck source=lib/install.sh
source "$WG_MANAGER_ROOT/lib/install.sh"
# shellcheck source=lib/clients.sh
source "$WG_MANAGER_ROOT/lib/clients.sh"
# shellcheck source=lib/diagnostics.sh
source "$WG_MANAGER_ROOT/lib/diagnostics.sh"
# shellcheck source=lib/maintenance.sh
source "$WG_MANAGER_ROOT/lib/maintenance.sh"
# shellcheck source=lib/menu.sh
source "$WG_MANAGER_ROOT/lib/menu.sh"
# shellcheck source=lib/cli.sh
source "$WG_MANAGER_ROOT/lib/cli.sh"
# shellcheck source=lib/prepare.sh
source "$WG_MANAGER_ROOT/lib/prepare.sh"

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  main "$@"
fi
