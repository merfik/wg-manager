# wg-manager

`wg-manager` is an interactive Bash tool that sets up and manages WireGuard on a Linux server. You run it from a terminal with root access. It asks questions, then creates the configs, keys, firewall rules, and service settings for you.

## 1. Overview

A working WireGuard server needs several pieces: a server config, keys, client configs, firewall rules, IP forwarding, and a running service. `wg-manager` manages those pieces from one menu. This reduces manual config editing and setup mistakes.

The tool can:

- Check the server and install missing packages.
- Install a WireGuard interface in one of two modes.
- Add, remove, list, show, and export client configs. QR codes are available when `qrencode` is installed.
- Show status and run a diagnostics ("doctor") report.
- Back up, restore, and uninstall an interface.

| Mode | What client traffic uses the tunnel |
| --- | --- |
| Hub-and-spoke (`hub`) | The tunnel subnet. |
| Full-tunnel (`full`) | All IPv4 and IPv6 traffic. You can choose split-tunnel routes instead. |

During installation the tool writes a server config at `/etc/wireguard/<interface>.conf`, stores keys and records under `/var/lib/wg-manager`, enables IP forwarding in `/etc/sysctl.d`, adds firewall rules through UFW, firewalld, or iptables, and starts a `wg-quick` service through systemd or OpenRC. If the new interface fails to start, the tool removes the changes it made.

## 2. Prerequisites / Setup

### Access and system

- Root access. Use `sudo` for installation and for actions that change the server. Read-only actions such as listing or showing a config may still need root to read the private files. The requirements check (`--prepare`) alone does not need root.
- A Linux server running Debian, Ubuntu, Fedora, RHEL, Rocky, AlmaLinux, Arch, or Alpine. These are the distributions the tool knows how to install packages on.
- systemd or OpenRC for the service. If neither is present, the tool still starts the interface with `wg-quick up`, but it does not create a boot service.
- The WireGuard kernel module. The installer also mentions `wireguard-go` for systems without kernel support.
- At least one firewall backend: an active UFW, a running firewalld, or installed iptables. UFW is the recommended choice.
- A default route on the server. Full-tunnel mode uses it to find the WAN interface.
- A public IP address or hostname that clients can reach, and a UDP port open to them. The default port is `51820`.
- A tunnel subnet that does not overlap an existing route on the server.

### Required commands

The tool checks for these commands. `--prepare` shows the exact package name for your distribution.

| Command(s) | Debian / Ubuntu | Fedora / RHEL / Rocky / AlmaLinux | Arch | Alpine |
| --- | --- | --- | --- | --- |
| `wg`, `wg-quick` | wireguard-tools | wireguard-tools | wireguard-tools | wireguard-tools |
| `ip`, `ss` | iproute2 | iproute | iproute2 | iproute2 |
| `python3` | python3 | python3 | python | python3 |
| `sysctl` | procps | procps-ng | procps-ng | procps |
| `awk` | gawk | gawk | gawk | gawk |
| `cat`, `chmod`, `date`, `head`, `install`, `mkdir`, `paste`, `rm` | coreutils | coreutils | coreutils | coreutils |
| `find` | findutils | findutils | findutils | findutils |
| `getent` | glibc | glibc | glibc | musl-utils |
| `grep` | grep | grep | grep | grep |
| `sed` | sed | sed | sed | sed |
| `tar` | tar | tar | tar | tar |

Optional commands:

| Command | Package | Used for |
| --- | --- | --- |
| `curl` | curl | Detecting the public IP when you leave the endpoint blank. |
| `qrencode` | qrencode | QR codes in the terminal and QR image files on export. |

### Step 1: Get the tool and check the server

Copy the repository to the server, change into its directory, and check the requirements:

```bash
cd wg-manager
./wg-manager.sh --help
./wg-manager.sh --prepare
```

`--prepare` prints a table with `installed` or `MISSING` for each command. It also reports missing packages and whether a firewall backend is active.

### Step 2: Install missing packages (optional)

```bash
sudo ./wg-manager.sh --prepare-install
```

The tool lists the packages it will install, asks `Proceed with installation? [y/N]`, uses the package manager for your distribution, and then checks again.

### Step 3: Open the main menu

```bash
sudo ./wg-manager.sh
```

Only `--help`, `-h`, `--prepare`, and `--prepare-install` work as command-line options. Everything else is done in the menu. Old subcommands such as `install` or `list` are rejected.

### Where the tool stores files

| Path | Contents |
| --- | --- |
| `/etc/wireguard/<interface>.conf` | Server config and peer entries. Secret. |
| `/var/lib/wg-manager/interfaces/<interface>/metadata` | Saved settings for the interface. |
| `/var/lib/wg-manager/interfaces/<interface>/server-private.key` | Server private key. Secret. |
| `/var/lib/wg-manager/interfaces/<interface>/server-public.key` | Server public key. |
| `/var/lib/wg-manager/clients/<interface>/<client>.conf` | Client config. Secret. |
| `/var/lib/wg-manager/clients/<interface>/<client>.private` | Client private key. Secret. |
| `/var/lib/wg-manager/clients/<interface>/<client>.public` | Client public key. |
| `/var/lib/wg-manager/clients/<interface>/<client>.psk` | Client preshared key, when enabled. Secret. |
| `/etc/sysctl.d/99-wg-manager-<interface>.conf` | IP forwarding settings. |

The default paths come from variables such as `WG_MANAGER_STATE_ROOT` and `WG_MANAGER_ETC_ROOT`. The examples in this guide use the defaults.

## 3. Step-by-step usage

### 3.1 Find your way around the menus

With no managed interfaces, the main menu shows:

```text
WireGuard manager
  No managed interfaces found.
  1) Prepare system (check/install dependencies)
  2) Install WireGuard
  0) Exit
Select an action:
```

After you install an interface, the main menu offers `1) Manage an interface`, `2) Install an interface`, `3) Prepare system`, and `0) Exit`. Choosing to manage an interface opens this menu:

```text
Interface wg0
  1) Add client
  2) Remove client
  3) List clients
  4) Show client config / QR
  5) Export client config / QR image
  6) Show status
  7) Run diagnostics
  8) Reconfigure hub/full mode
  9) Back up interface
 10) Restore backup
 11) Uninstall interface
  0) Back
Select an action:
```

Several actions first ask `Run as a dry run only? [y/N]`. Answer `y` to preview the action without making changes. This applies to install, remove client, reconfigure, backup, restore, and uninstall.

### 3.2 Install a WireGuard interface

Start with main menu option `2) Install WireGuard`. The tool suggests the first unused `wgN` name and validated defaults. Press Enter to accept a default.

This example installs a hub-and-spoke interface. Use your own public IP address; `203.0.113.10` is only an example.

```text
Interface name [wg0]:
Select tunnel mode:
  1) Hub-and-spoke
  2) Full-tunnel VPN
Mode [1]: 1
IPv4 tunnel subnet [10.7.0.0/24]:
WireGuard UDP port [51820]:
Client MTU [1420]:
Persistent keepalive in seconds (0 disables it) [25]:
Optional IPv6 ULA CIDR (leave blank to skip):
Public endpoint (IP or hostname): 203.0.113.10

Installation summary
  Interface: wg0
  Mode: hub
  Tunnel subnet: 10.7.0.0/24
  Port: 51820/UDP
  MTU: 1420
  IPv6: disabled
  DNS: system
  Endpoint: 203.0.113.10
Proceed with installation? [y/N]: y
Run as a dry run only? [y/N]: n
```

The tool checks that the subnet does not overlap existing routes, creates the keys and configs, opens the UDP port, enables forwarding, and starts the service. It finishes with `Installed wg0 in hub mode.` and asks `Add a client now? [Y/n]`.

Accepted values (the client name applies when you add a client):

| Setting | Rule |
| --- | --- |
| Interface name | 1-15 characters. Starts with a letter. Then letters, digits, `_`, `.`, or `-`. |
| Mode | `1` for hub-and-spoke or `2` for full-tunnel. |
| Tunnel subnet | IPv4 CIDR, for example `10.7.0.0/24`. It must not overlap an existing route. |
| UDP port | 1-65535. |
| Client MTU | 1280-1500. |
| Keepalive | `0` disables it. Otherwise 1-86400 seconds. |
| IPv6 ULA CIDR | Private IPv6 CIDR, for example `fd00:7::/64`. Leave blank to skip. |
| Public endpoint | IPv4 address or DNS hostname. Required in hub mode. |
| Client name | 1-32 letters, digits, dots, underscores, or hyphens. |

**Full-tunnel mode.** Select `2` at the mode prompt. You may leave the endpoint blank; the tool then tries to detect your public IP through `api.ipify.org`, which needs `curl`. Then it asks:

```text
Enable split-tunnel routes instead of sending all traffic through the VPN? [y/N]:
```

Answer `y` and enter comma-separated IPv4 CIDRs to send only those routes through the VPN. After you confirm installation and the dry-run question, the tool also asks `Use WAN interface 'eth0'? [y/N]` and shows a DNS menu with system, Cloudflare, Google, Quad9, OpenDNS, and custom options.

### 3.3 Add a client

If you skipped the prompt after installation, open the interface menu with main menu option `1`, then choose `1) Add client`.

```text
Client name (letters, digits, dot, underscore, hyphen): phone
Generate a preshared key for this client? [y/N]: n
Added client 'phone'. Its private config is at /var/lib/wg-manager/clients/wg0/phone.conf
```

A preshared key adds another secret shared by the server and the client. Answer `y` if your client setup supports it.

The tool generates the client keys, picks the next free tunnel address, writes the client config with mode `600` permissions, adds a peer entry to the server config, and applies the change to the running interface.

### 3.4 List, show, and export clients

- **List clients** (interface menu option `3`) prints the interface, mode, subnet, and every client name.
- **Show client config / QR** (option `4`) asks for the client name, then `Also print a QR code in the terminal? [y/N]`. It prints the full config. A QR code needs `qrencode`. Treat the output as secret; do not share screenshots.
- **Export client config / QR image** (option `5`) asks for the client name and an export directory. Leave the directory blank to use the current directory. It copies a mode `600` config file. It also writes a PNG QR file when `qrencode` is installed.

### 3.5 Check status and run diagnostics

- **Show status** (option `6`) runs `wg show` for the interface. If the interface is down, the tool prints the exact command to start it, such as `systemctl start wg-quick@wg0`.
- **Run diagnostics** (option `7`) prints a report like this:

```text
Doctor report for wg0 (hub mode)
  [ok] wireguard-tools is installed
  [ok] interface is present
  [ok] IPv4 forwarding is enabled
  [ok] UDP port 51820 is listening
  [info] active firewall backend: ufw
  [ok] DNS resolution works
```

Full-tunnel mode adds a MASQUERADE rule check. If you set an IPv6 CIDR, the report adds an IPv6 forwarding check. Any `[FAIL]` line makes the report return a failure status. The MASQUERADE `[WARN]` line does too.

### 3.6 Reconfigure hub/full mode — known limitation

Interface menu option `8` is present, but the current code always fails when you select it:

```text
Reconfigure requires --mode hub or --mode full.
```

The tool reads a setting that the menu never supplies. There is no working mode switch in this version. Do not rely on this option to change a live interface.

### 3.7 Back up and restore

- **Back up interface** (option `9`) asks for a file name. Press Enter to use `<interface>-backup-<timestamp>.tar.gz` in the current directory. After the dry-run question, it saves the server config, interface state, client files, and sysctl file into a gzip tar archive with mode `600`. It prints a SHA-256 checksum and the file path.
- **Restore backup** (option `10`) asks for the archive path and the dry-run question, then asks `Restore WireGuard backup '<file>'? This may replace managed files.`. It validates the archive, reads the interface name from the archive metadata, extracts the files, reapplies forwarding and firewall rules, and starts the service. Keep the archive until you confirm the restore worked.

### 3.8 Uninstall an interface

Interface menu option `11` asks the dry-run question and then:

```text
Uninstall interface 'wg0' and remove all of its keys and configs? [y/N]:
```

Answering `y` stops the service, removes the firewall rules, and deletes the server config, sysctl file, keys, peers, metadata, and client files. Take a backup first if you may need the configs later.

### Handle secrets carefully

Client configs, private keys, preshared keys, server keys, backups, and QR codes grant VPN access. The tool sets restrictive file permissions, but you should still store and share these files with care. The `show` action prints an explicit warning before displaying a config.

## 4. Common errors and troubleshooting

| Message or symptom | What to do |
| --- | --- |
| `Root access is required. Re-run this command with sudo.` | Run the command with `sudo`. Only `--help`, `-h`, and `--prepare` work without root. |
| `The command-line interface has been replaced by interactive menus. Run '<script-name>' without arguments.` | Use the menu. Only `--help`, `-h`, `--prepare`, and `--prepare-install` are accepted as options. |
| `Unsupported distribution '<name>' for package installation.` | `--prepare-install` supports Debian, Ubuntu, Fedora, RHEL, Rocky, AlmaLinux, Arch, and Alpine. Install the packages from the `--prepare` table with your own package manager. |
| `Package installation failed.` | Check your package manager output and network access. If the install list shows `ufw (recommended)`, install `ufw` manually and run `--prepare-install` again. |
| `Interface '<name>' already has WireGuard or manager state. Choose another interface or manage the existing one.` | Pick a different interface name, or manage the existing one from the main menu. |
| `Invalid interface name`, `Invalid listen port`, `Invalid MTU`, `Invalid keepalive`, `Invalid CIDR`, `Invalid IPv6 ULA CIDR`, `Invalid endpoint`, or `Invalid DNS` | Re-enter the value using the rules in the setup table in section 3.2. The setup prompts re-ask invalid values. |
| `Invalid client name` | Use 1-32 letters, digits, dots, underscores, or hyphens. |
| `Invalid DNS selection '<choice>'. Enter 1-6.` or `Invalid mode selection '<choice>'. Enter 1, 2, or 3.` | Choose one of the numbered options shown in the menu. |
| `The tunnel subnet '<network>' overlaps existing route '<route>' on '<interface>'.` | Choose another tunnel subnet or remove the conflicting route. |
| `No WAN interface was detected from the default route.` | Full-tunnel mode needs a default route. Fix the server network configuration and retry. |
| `Detected WAN interface '<name>' is unavailable.` | Check the server network configuration, then retry. |
| `Could not detect a public endpoint IP. Set --endpoint to a public hostname or IP.` | Enter the public IP or hostname at the `Public endpoint` prompt. The message names an old option; the menu prompt replaces it. Auto-detection also needs `curl`. |
| `Missing WireGuard tools. Install 'wireguard-tools' and the WireGuard kernel module ...` | Install `wireguard-tools` and the kernel module (or `wireguard-go`), then retry. |
| `No supported firewall backend is active or installed.` | Install and configure UFW, firewalld, or iptables before installing an interface. |
| `Interface '<name>' failed to start and partial changes were rolled back. Run 'wg-manager doctor --iface <name>' ...` | Fix the service error first. The named doctor command is old text; open the interface menu and choose `7) Run diagnostics`. |
| `Client '<name>' already exists. Remove it before adding it again.` | Remove the client first, or use another name. |
| `No tunnel addresses remain in '<subnet>'.` | Use a larger subnet at install time or remove a client to free an address. |
| `Client '<name>' is not present on interface '<iface>'` or `has no config on interface '<iface>'` | Run `3) List clients` and check the name. Messages that say `wg-manager list --iface` are old text. |
| `QR output is required but qrencode is missing.` | Install `qrencode`, or answer `n` to the menu's QR question. The error text mentions an old `--qr` option. |
| `qrencode is missing, so only the config file was exported.` | The config exported successfully. Install `qrencode` and export again to get the PNG. |
| `Backup creation failed for '<iface>'. Check the output path and available disk space.` | Check that the output directory exists and has free space. |
| `Backup file '<file>' does not exist.` / `is not a valid gzip tar archive` / `has no usable interface metadata` | Check the path, or create a new backup with option `9`. Restoring requires the archive to contain a `metadata` file. |
| `Status is unavailable; see the error above.` | The interface is down. Start it with the command printed by `6) Show status`, then retry. |
| `Reconfigure requires --mode hub or --mode full.` | This is the known limitation in section 3.6. The current menu cannot switch modes. |

Doctor report lines and what they mean:

| Report line | Action |
| --- | --- |
| `[FAIL] wireguard-tools missing` | Install `wireguard-tools` and the kernel module. |
| `[FAIL] interface is down` | Start `wg-quick@<interface>` or `rc-service wg-quick.<interface>`. |
| `[FAIL] IPv4 forwarding is disabled` | Check `/etc/sysctl.d/99-wg-manager-<interface>.conf` and the service state. |
| `[FAIL] IPv6 forwarding is disabled` | Enable `net.ipv6.conf.all.forwarding`. The tool writes this setting when you configure an IPv6 CIDR. |
| `[FAIL] UDP port <port> is not listening` | Check the firewall and the service logs. |
| `[WARN] MASQUERADE rule not found` | Shown in full-tunnel mode when the tool cannot find an iptables NAT rule. Review the firewall setup before treating it as an outage. |
| `[FAIL] DNS resolution failed` | Check `/etc/resolv.conf` or the selected DNS provider. |

Several error messages name options such as `--iface`, `--subnet`, `--mode`, or `--endpoint`. Those options are no longer accepted. Set the same values at the menu prompts.
