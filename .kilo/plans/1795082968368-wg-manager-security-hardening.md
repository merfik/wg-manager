# wg-manager security and correctness hardening

## Goal

Remove the code-execution paths in metadata/preset handling, make backup restore safe, eliminate predictable root-owned temp files, and fix the functional bugs that make multi-client and UFW full-tunnel setups incorrect. Existing interfaces are repaired by re-adding clients; nothing is migrated silently.

## Decisions taken

- Scope: security fixes plus functional correctness. Package-DB cleanup, shebang, and pure style items are out of scope.
- UFW full-tunnel NAT: managed block in `/etc/ufw/before.rules` (before the first `*filter`), mirrored to the state dir as the source of truth so backup, restore, reconfigure, and uninstall can add/remove it precisely.
- Existing broken interfaces: fix forward, and surface the problem in `command_doctor` with exact remediation. No automatic rewriting of deployed peers.

## Verified findings and dispositions

| Finding | File | Action |
|---|---|---|
| `read_metadata` sources the metadata file | `lib/common.sh:265` | Replace with allowlisted key/value parser |
| `restore` untars arbitrary content to `/` | `lib/maintenance.sh:91` | Validate members, stage, install files |
| Preset file is sourced | `lib/cli.sh:52` | Replace with allowlisted parser |
| Predictable `/tmp/wg-strip-<iface>.conf` written as root | `lib/clients.sh:34,74` | `mktemp` under state dir |
| `CLIENT` from a preset is unvalidated but used in `rm -f "$dir/$CLIENT".*` | `lib/clients.sh:72`, `lib/cli.sh:71` | Add `validate_client` |
| `command_remove` splits text on `"\n[Peer]"` | `lib/clients.sh:59-70` | Line-based parser, CRLF safe |
| `wg syncconf` failures ignored | `lib/clients.sh:35,75` | Check status, roll back config |
| UFW MASQUERADE never applied | `lib/network.sh:145-151` | Apply via `before.rules` managed block |
| `allocate_client_ip` scans `Address=` but peers use `AllowedIPs =` | `lib/network.sh:85-103` | Parse both, exclude network/broadcast/server |
| Peer `AllowedIPs = <addr>/24` masks to whole subnet | `lib/clients.sh:30` | Emit `/32` per peer |
| Metadata non-atomic, omits `SPLIT_TUNNEL`/`ROUTES` | `lib/common.sh:278-299` | `umask 077` + temp + `mv`, add keys |
| `route_conflict` conflates gateways with interfaces | `lib/network.sh:39` | Compare destination prefixes only |
| CIDR regex accepts leading zeros | `lib/common.sh:120` | Strict octet regex |
| `detect_endpoint` hides failure cause | `lib/network.sh:41-47` | Log curl exit code and hint |
| `command_reconfigure` unreachable (`MODE_ARG` never set, no `--mode`) | `lib/menu.sh:217`, `lib/cli.sh:23` | Wire menu and CLI |
| `check_system_requirements` dead, duplicates root logic | `lib/common.sh:198` | Delete |

Deliberately unchanged: `pkg_install`'s `apt-get update` (apt verifies signatures; update is required), the `declare -A PKG_*` block, the shebang, `distro_detect`, and the `set -euo pipefail` inheritance.

## Task list

### 1. `lib/common.sh` — safe parsing, validation, atomic metadata

1.1 Add `declare -gA KV=()` near the other globals and a shared parser used by metadata and presets:

```bash
# Fills the global associative array KV from a KEY=VALUE file.
# - strips CR, skips blank lines and full-line comments
# - strips an inline comment only when preceded by whitespace
# - strips one layer of surrounding single/double quotes and trims spaces
# - returns non-zero on a non-blank line that is not KEY=VALUE
parse_kv_file() {
  local file=$1 line key value
  KV=()
  while IFS= read -r line || [[ -n $line ]]; do
    line=${line%$'\r'}
    [[ $line =~ ^[[:space:]]*(#|$) ]] && continue
    [[ $line =~ ^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*=(.*)$ ]] || return 1
    key=${BASH_REMATCH[1]}
    value=${BASH_REMATCH[2]}
    value=${value%%[[:space:]]#*}
    value=${value#"${value%%[![:space:]]*}"}
    value=${value%"${value##*[![:space:]]}"}
    if [[ $value == \"*\" || $value == \'*\' ]]; then
      value=${value:1:${#value}-2}
    fi
    KV[$key]=$value
  done <"$file"
}
```

Inline-comment stripping must only trigger on whitespace-then-`#`, so `wg-preset.env` lines like `WG_MODE=hub          # hub | full` parse as `hub` and `WG_IPV6=             # leave blank` parses as empty.

1.2 Rewrite `read_metadata` (`lib/common.sh:260`):

- Keep the existing "not managed by wg-manager" guard.
- Call `parse_kv_file`; `die` on malformed content.
- Reject any key outside the fixed set: `MODE IFACE SUBNET IPV6 PORT ENDPOINT DNS MTU KEEPALIVE WAN FIREWALL SERVICE_BACKEND SPLIT_TUNNEL ROUTES PSK CREATED_AT`.
- Assign only those keys explicitly (no `source`, no `declare -n`, no `eval`).
- If the stored `IFACE` is non-empty and differs from the current `IFACE`, `die` (this prevents a crafted metadata file from steering `rm -rf "$(metadata_dir)"` in `command_uninstall`).
- Run `validate_iface` on the stored name.
- Default `SPLIT_TUNNEL` to `0` and `ROUTES` to empty when absent, so old metadata and old backups still load.

1.3 Rewrite `write_metadata` (`lib/common.sh:278`):

- `umask 077`, `mktemp "$dir/.metadata.XXXXXX"`, write with `printf '%s\n'`, `chmod 600`, `mv -f` into place.
- Add `SPLIT_TUNNEL=${SPLIT_TUNNEL:-0}` and `ROUTES=${ROUTES:-}`.
- Guard values against embedded newlines (`[[ $v == *$'\n'* ]] && die`).

1.4 Add `validate_client`, and reuse the same pattern in `lib/menu.sh:137`:

```bash
validate_client() {
  [[ $CLIENT =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]{0,31}$ ]] || {
    log ERROR "Invalid client name '$CLIENT'. Use 1-32 letters, digits, dots, underscores, or hyphens, starting with a letter, digit, or underscore."
    return 1
  }
}
```

Call it at the top of `command_add`, `command_remove`, `command_show`, `command_export` and after preset mapping in `cli_load_preset`.

1.5 Tighten `validate_cidr` (`lib/common.sh:118`) and drop the octet loop:

```bash
local octet='(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])'
if [[ ! $cidr =~ ^$octet(\.$octet){3}/(0|[12]?[0-9]|3[0-2])$ ]]; then
```

`10.7.0.0/24` and `10.7.0.0/0` stay valid; `999.7.0.0/24` and `10.001.002.003/24` are rejected.

1.6 Delete the unused `check_system_requirements` (`lib/common.sh:198-218`).

### 2. `lib/cli.sh` — safe preset loading

2.1 Replace `. "$WG_PRESET_FILE"` with a `load_preset_file` helper built on `parse_kv_file`:

- Whitelist exactly the `WG_*` names documented in README §4.2.
- Assign with `printf -v "$key" '%s' "${KV[$key]}"` using the whitelisted name only.
- Unknown `WG_*` keys: `log WARN "Ignoring unknown preset variable '<key>'"`. Non-`WG_` keys: `log WARN` and ignore.
- No `source`, no command substitution, no `eval`; a value containing `$(...)` or backticks is stored literally and later rejected by the relevant validator.

2.2 Add `--mode <hub|full>` to `cli_parse` (writes `MODE_ARG`, validates the value), and mention it in `usage` (`lib/common.sh`) and README §4.1.

### 3. `lib/network.sh` — allocation, routes, UFW NAT

3.1 Rewrite `allocate_client_ip` (`lib/network.sh:85`) to keep printing `<address>/<prefix>` but derive `used` from peer entries:

```python
network = ipaddress.IPv4Network(sys.argv[1], strict=False)
used = set()
for line in open(sys.argv[2], encoding="utf-8"):
    key, _, val = line.partition("=")
    if key.strip() in ("Address", "AllowedIPs"):
        for item in val.split(","):
            try:
                used.add(ipaddress.IPv4Address(item.strip().split("/")[0]))
            except ValueError:
                pass
for addr in network.hosts():          # excludes network + broadcast
    if addr not in used:
        print(f"{addr}/{network.prefixlen}")
        break
```

This fixes every client receiving `10.7.0.2` and covers the server address from the `[Interface]` block.

3.2 `command_add` (`lib/clients.sh:30`): write the peer as `AllowedIPs = ${client_ip%/*}/32` so a peer never claims the whole tunnel subnet. Die with the existing "no tunnel addresses remain" message when `allocate_client_ip` prints nothing.

3.3 `route_conflict` (`lib/network.sh:19-40`): read only destination prefixes.

```bash
while read -r dest _rest; do
  [[ -n $dest && $dest != "$network" && $dest != default ]] || continue
  python3 - "$dest" "$network" <<'PY' >/dev/null 2>&1
...
PY
  ... die "The tunnel subnet '$network' overlaps existing route '$dest'."
done < <(ip -4 route show 2>/dev/null | awk '{print $1}')
```

Update the README error-table row for this message (it currently names an interface).

3.4 UFW full-tunnel NAT:

- Add `UFW_RULES=${WG_MANAGER_UFW_RULES:-/etc/ufw/before.rules}` beside the other root overrides in `lib/common.sh` (needed for tests).
- `ufw_nat_file()` returns `"$STATE_ROOT/interfaces/$IFACE/ufw-nat.rules"`.
- `apply_ufw_nat()`:
  1. Write the state mirror atomically (`umask 077`, temp + `mv`, mode 600):
     ```
     # BEGIN wg-manager <iface>
     *nat
     :POSTROUTING ACCEPT [0:0]
     -A POSTROUTING -o <wan> -j MASQUERADE
     COMMIT
     # END wg-manager <iface>
     ```
  2. Use a `python3` helper to read `$UFW_RULES`, delete any `# BEGIN wg-manager <iface>` … `# END wg-manager <iface>` region, then insert the new region immediately before the first line matching `^\*filter`. Abort if no `*filter` line exists (unknown layout — do not guess).
  3. Preserve the file's existing mode/owner; write atomically via temp + `os.replace`.
  4. `ufw --force reload`; on failure `die` with the ufw output.
  5. Verify with `iptables -t nat -S POSTROUTING | grep -q -- "-o $WAN -j MASQUERADE"`.
- `remove_ufw_nat()`: same removal step, `ufw --force reload`, tolerate a missing block.
- `add_firewall_rules` ufw/full branch calls `apply_ufw_nat` and keeps `ufw route allow in on "$IFACE" out on "$WAN"`. Delete the `ufw-masq` writer.
- `remove_firewall_rules` ufw branch calls `remove_ufw_nat` and `rm -f` any legacy `.../ufw-masq`.
- `DRY_RUN` prints the block and the target file instead of writing.
- `command_uninstall` must call `remove_ufw_nat` before deleting `$(metadata_dir)`; store `WAN` in metadata (already written) so the removal works without route detection.

3.5 `detect_endpoint` (`lib/network.sh:41`): capture the curl status and log it.

```bash
local rc=0
ENDPOINT=$(curl -4fsS --max-time 5 https://api.ipify.org 2>/dev/null) || rc=$?
[[ -n $ENDPOINT ]] || die "Could not detect a public endpoint IP (curl exit $rc). Enter the public IP or hostname at the prompt, or install/repair curl and any proxy settings."
```

### 4. `lib/clients.sh` — safe temp files and verified sync

4.1 Replace both `/tmp/wg-strip-"$IFACE".conf` uses with a private temp dir:

```bash
local tmp
tmp=$(mktemp -d "$STATE_ROOT/interfaces/$IFACE/.sync.XXXXXX")
trap 'rm -rf "$tmp"' RETURN   # RETURN trap fires when the enclosing command function exits
```

4.2 `command_add`:

1. `validate_client`; `validate_iface`.
2. Snapshot the current server config to `$tmp/prev.conf`.
3. Append the `[Peer]` block to `$ETC_ROOT/$IFACE.conf` as today (with `/32`), `chmod 600`.
4. If `ip link show "$IFACE"` succeeds: `wg-quick strip "$IFACE" >"$tmp/stripped.conf"` then `wg syncconf "$IFACE" "$tmp/stripped.conf"`. On either failure, restore `$tmp/prev.conf`, resync, remove the client key/config files, and `die` with the underlying error.
5. If the interface is down, log `INFO` that the peer applies on next start instead of failing.

4.3 `command_remove`:

1. `validate_client`; confirm; compute `key` from the `.public` file.
2. Line-based rewrite (no `split("\n[Peer]")`): read the file with `newline=''`, group lines into the interface header plus `[Peer]` sections (a section starts at a line whose `strip()` equals `[Peer]`), drop the section containing an exact `PublicKey = <key>` match, preserve every other byte, write via temp + `os.replace` with mode 600.
3. Sync as in 4.2, rolling back the config on failure.
4. `rm -f "$client_dir/$CLIENT".*` only after a successful sync.
5. Drop `wg set "$IFACE" peer "$key" remove` — `wg syncconf` reconciles removals and the subcommand requires newer wireguard-tools.

### 5. `lib/maintenance.sh` — validated restore

5.1 `command_restore`:

1. Keep the gzip validity check; additionally fail if `tar -tzf` yields no members.
2. Reject the archive if any member is absolute, contains a `..` component, or contains a backslash; reject any member whose `tar -tvzf` type character is not `-` (no symlinks, hardlinks, devices, directories used as escapes).
3. Derive `IFACE` from the single member matching `^<state_rel>/interfaces/([^/]+)/metadata$`, where `<state_rel>=${STATE_ROOT#/}`; `validate_iface` it. Fail if zero or multiple candidates.
4. Build the expected path set for that interface:
   - `${ETC_ROOT#/}/$IFACE.conf`
   - `${STATE_ROOT#/}/interfaces/$IFACE/*`
   - `${STATE_ROOT#/}/clients/$IFACE/*`
   - `${SYSCTL_DIR#/}/99-wg-manager-$IFACE.conf`
   Every member must match one of these prefixes; anything else aborts before extraction.
5. Extract to a staging dir (`mktemp -d`) with `tar -xzf "$file" -C "$stage" --no-same-owner --no-same-permissions`, then install files individually with `install -d -m 700` / `install -m 600`. Never `tar -C /`.
6. Only after staging succeeds: `read_metadata`, `enable_forwarding`, `add_firewall_rules "$FIREWALL"` (now applies UFW NAT), `install_service start`, remove a legacy `ufw-masq` file, `rm -rf "$stage"`.
7. `DRY_RUN` performs steps 1–4 and prints the members it would install.

5.2 `command_backup`: unchanged behavior; the state mirror under `interfaces/<iface>/` is already captured and restored.

### 6. `lib/diagnostics.sh` — detect the forward-fix cases

Add to `command_doctor`, each with a specific remediation line:

- Duplicate tunnel addresses: collect peer `AllowedIPs` hosts from `$ETC_ROOT/$IFACE.conf`; report duplicates as `[FAIL] clients share address <ip>: remove and re-add the affected clients`.
- Non-`/32` peer AllowedIPs: `[FAIL] peer <key-prefix> claims <prefix>: remove and re-add that client`.
- Full-tunnel NAT per backend: ufw → grep for the managed block in `$UFW_RULES` **and** `iptables -t nat -S POSTROUTING`; firewalld → `firewall-cmd --zone=external --query-masquerade`; iptables → existing check. Keep the existing DNS check.

### 7. `lib/menu.sh` — reconfigure wiring and nullglob

- `menu_reconfigure`: capture the chosen mode before `command_reconfigure` overwrites `MODE` from metadata:
  ```bash
  menu_prompt_mode || return 0
  MODE_ARG=$MODE
  MODE=
  menu_run_with_dry_run command_reconfigure
  ```
- `menu_prompt_client` regex must match `validate_client` (`^[A-Za-z0-9_][A-Za-z0-9_.-]{0,31}$`) and use its wording.
- `command_list` (`lib/clients.sh:85`): save and restore the `nullglob` option instead of leaking `shopt -s nullglob` into the shell.

### 8. Tests — `tests/wg-manager.bats`

Keep every existing test green; add:

- Metadata is not executed: write a metadata file with `MODE=hub` plus `EVIL=$(touch "$BATS_TEST_TMPDIR/pwned")`; assert `read_metadata` fails and `pwned` does not exist.
- Metadata rejects an unknown key and an `IFACE` that differs from the requested one.
- Metadata round-trip includes `SPLIT_TUNNEL` and `ROUTES`; file mode is 600 and no `.metadata.*` temp file remains.
- Preset parsing: inline comments, blank values with trailing comments, quoted values; a `WG_CLIENT='$(id)'` value is stored literally and rejected by `validate_client`.
- `validate_cidr` accepts `10.7.0.0/24` and `/0`, rejects `999.7.0.0/24`, `10.001.002.003/24`.
- `allocate_client_ip` returns `10.7.0.3/24` when the server config already holds `.1` (interface) and `.2` (peer) — no duplicate.
- `command_add` writes `AllowedIPs = <ip>/32`; a failing `wg syncconf` stub leaves the config byte-identical to the snapshot and removes the new key files.
- `command_remove` on a CRLF config removes only the targeted peer and preserves the other peer and line endings.
- `command_restore` rejects an archive containing `etc/passwd` and an archive containing a symlink member, and writes nothing.
- `apply_ufw_nat` / `remove_ufw_nat` with `WG_MANAGER_UFW_RULES` pointed at a fixture: block inserted before `*filter`, existing content preserved, second apply is idempotent, removal restores the original.

### 9. Documentation — `README.md`

- §3.6: reconfigure now works (menu option 8 and `--mode`); delete the "always fails" note and the matching troubleshooting row.
- §4.1: add `--mode <hub|full>` for `--reconfigure`.
- §3.7: restore now validates archive contents and refuses unexpected paths.
- Full-tunnel: note that UFW NAT is applied as a managed block in `/etc/ufw/before.rules` and removed on uninstall or a switch to hub mode.
- Add a short note that client `DNS =` is written into the client config and honored by wg-quick on Linux but ignored by some platform clients.
- Update the route-conflict message row and troubleshooting rows that quote changed text.

## Validation

1. `bats tests/wg-manager.bats` — all existing and new tests pass.
2. `shellcheck -x wg-manager.sh lib/*.sh` — no new findings (pre-existing SC2034-type suppressions stay as they are).
3. Manual smoke test with `WG_MANAGER_STATE_ROOT`, `WG_MANAGER_ETC_ROOT`, `WG_MANAGER_SYSCTL_DIR`, `WG_MANAGER_UFW_RULES` pointed at a temp tree: install (dry run), add two clients, confirm distinct addresses and `/32` peer entries, remove one, backup, restore, uninstall.
4. On a disposable VM with UFW active: full-tunnel install, confirm the `before.rules` block and `iptables -t nat -S POSTROUTING` output, `ufw reload` and reboot persistence, then reconfigure to hub and confirm the block is gone.

## Risks and notes

- `ufw --force reload` briefly reprograms the firewall; warn in the README rather than prompt for it.
- Restore validation rejects archives that contain paths outside the managed set — including hand-made archives and archives from a different `STATE_ROOT`/`ETC_ROOT` layout. Document this in the error message.
- `parse_kv_file` strips inline comments only after whitespace, so a value containing `" #"` is truncated; acceptable for the validated value set and documented in a code comment.
- Metadata written by older versions stays readable (unknown-to-old keys are additive); backups made before this change still restore.
