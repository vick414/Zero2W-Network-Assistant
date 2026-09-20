# Zero2W Network Assistant

`configure-pi-router.sh` configures a Raspberry Pi Zero 2 W running 64-bit
Debian/Raspberry Pi OS as a small three-interface routed network appliance.

The script is designed to complete the main router setup even without Internet
access. Required tools such as NetworkManager and `nmcli` must already be present
on the OS image. If packet capture is enabled and `tcpdump` is missing, the
script attempts to install `tcpdump` only when `apt-get` is available and package
repositories are reachable.

## Network Layout

| Interface | Role | Addressing |
| --- | --- | --- |
| `eth0` | WAN/uplink | DHCP client, owns the IPv4 default route |
| `eth1` | Device LAN | `10.0.0.1/24`, DHCP range `10.0.0.100-10.0.0.250` |
| `wlan0` | Management Wi-Fi AP | `192.168.50.1/24`, DHCP range `192.168.50.100-192.168.50.200` |

The networks are routed networks. The script does not create a Layer 2 bridge.
Traffic from `eth1` and management Wi-Fi traffic are handled through
NetworkManager shared-mode routing/NAT behavior.

## What The Script Does

- Requires root and uses `set -Eeuo pipefail`.
- Verifies that `eth0`, `eth1`, and `wlan0` exist.
- Starts NetworkManager if the service exists but is not running.
- Enables SSH if `ssh.service` or `sshd.service` already exists.
- Creates or updates these NetworkManager profiles:
  - `WAN-ETH0`
  - `LAN-ETH1`
  - `MGMT-WIFI`
- Disables autoconnect for competing profiles, including profiles such as
  `netplan-eth0` that could race `WAN-ETH0`.
- Generates the management Wi-Fi SSID from the last three bytes of the `wlan0`
  MAC address, for example `pi_A1B2C3`.
- Uses the generated SSID as the default WPA2 password, for example
  `pi_A1B2C3`. This keeps provisioning simple while still meeting the WPA2
  minimum passphrase length.
- Stores Wi-Fi credentials in `/root/pi-router-wifi.txt` with `0600`
  permissions.
- Preserves a manually changed password on later runs.
- Installs managed packet-capture controls and, when Internet/package repository
  access is available, installs `tcpdump` if needed.
- Optionally installs an isolated transparent MITM subsystem when
  `ENABLE_MITM=yes`. Interception remains disabled unless explicitly enabled.

## Requirements

Essential commands must already be available:

```bash
bash nmcli ip systemctl readlink awk sed grep tr head cut cat chmod mkdir tee cp mv rm date
```

Optional commands:

- `tcpdump`: enables rotating packet capture on `eth1`. If missing, the script
  tries to install it with `apt-get` when repository access is available.
- `raspi-config` or `iw`: used when available to set the Wi-Fi country.
- `rfkill`: used when available to unblock Wi-Fi.
- `useradd`, `getent`, `install`, `chown`, `find`, `stat`, `sort`, `du`, and
  `wc`: required to install and operate the managed packet-capture subsystem.
- `iptables` and `sysctl`: required only when installing the optional
  transparent MITM subsystem.
- `mitmdump`: required to activate MITM. With `ENABLE_MITM=yes`, the script
  attempts to install the latest official standalone mitmproxy build when
  Internet access is available.

The script does not install NetworkManager. It may install `tcpdump` for packet
capture and `curl`/CA certificates when needed to download the optional official
mitmproxy build.

## Usage

Copy the script to the Raspberry Pi and run:

```bash
chmod +x configure-pi-router.sh
sudo ./configure-pi-router.sh
```

Show built-in help:

```bash
./configure-pi-router.sh --help
```

Supported environment variables:

```bash
WIFI_COUNTRY=US
AP_CHANNEL=6
ENABLE_CAPTURE=yes
CAPTURE_AUTO_START=yes
ENABLE_MITM=no
MITM_AUTO_START=no
MITM_DEFAULT_MODE=web
```

Example:

```bash
sudo WIFI_COUNTRY=US AP_CHANNEL=6 ENABLE_CAPTURE=yes ./configure-pi-router.sh
```

Install the MITM controls without activating interception:

```bash
sudo ENABLE_MITM=yes ./configure-pi-router.sh
```

When an IPv4 default route and Internet access are available, this also checks
the official mitmproxy download index and installs the newest standalone build
published for the detected architecture. Supported automatic mappings are:

```text
x86_64 / amd64 -> linux-x86_64
aarch64 / arm64 -> linux-aarch64
```

The managed binaries are installed in `/opt/zero2w-mitm/bin`. If the download,
archive validation, or executable test fails, an existing installation is
preserved and router provisioning continues.

`MITM_AUTO_START=yes` is available for an explicitly persistent setup, but is
not the default:

```bash
sudo ENABLE_MITM=yes MITM_AUTO_START=yes MITM_DEFAULT_MODE=web ./configure-pi-router.sh
```

Use `ENABLE_CAPTURE=no` to skip packet capture setup:

```bash
sudo ENABLE_CAPTURE=no ./configure-pi-router.sh
```

With `ENABLE_CAPTURE=yes`, if `tcpdump` is missing and the Pi has working access
to configured Debian/Raspberry Pi package repositories, the script runs:

```bash
apt-get update
apt-get install -y tcpdump
```

If those commands fail, router provisioning continues and capture remains
disabled. The capture control files are still installed, so the service can be
enabled after installing `tcpdump` locally.

## Wi-Fi Credentials

By default, the management Wi-Fi SSID and password are the same value:

```text
SSID:     pi_A1B2C3
Password: pi_A1B2C3
```

The suffix comes from the last three bytes of the `wlan0` MAC address. The
password includes the `pi_` prefix because WPA2 passwords must be at least 8
characters long; the raw last three MAC bytes are only 6 hex characters.

Credentials are stored in:

```text
/root/pi-router-wifi.txt
```

To manually set a different password, run:

```bash
chmod +x set-pi-router-wifi-password.sh
sudo ./set-pi-router-wifi-password.sh
```

The helper prompts for the new password twice, validates that both entries
match, updates the NetworkManager `MGMT-WIFI` profile, updates
`/root/pi-router-wifi.txt`, and restarts the Wi-Fi AP profile. Current Wi-Fi
management clients will disconnect during the restart.

## Packet Capture

The capture subsystem follows the same managed-control pattern as the optional
MITM subsystem. Keep the repository's `capture` directory beside
`configure-pi-router.sh`. With `ENABLE_CAPTURE=yes`, the script creates:

```text
/etc/systemd/system/eth1-capture.service
/etc/default/zero2w-capture
/usr/local/sbin/zero2w-capture
/usr/local/libexec/zero2w-capture-*
/var/log/pcap
```

It is safe to rerun the updated provisioning script on a Pi configured by an
older project version. The previous unit is stopped and backed up before the
managed unit is installed. Existing matching PCAP files are preserved and their
ownership is updated for the dedicated service account. A recognized obsolete
`eth1-capture-start.sh` is removed; an operator-modified file at that path is
left unchanged and is no longer referenced by the unit.

By default, `CAPTURE_AUTO_START=yes` enables the service at boot. It raises
`eth1` administratively and attaches `tcpdump` while the Ethernet carrier is
still down. Keeping the listener ready is intentional: it captures the first
ARP, DHCP, or other packet sent as soon as a cable and device are connected.
NetworkManager still manages addressing, link detection, routing, and NAT, so a
separate service to keep Ethernet interfaces up is not required.

`tcpdump` runs as the dedicated `zero2w-capture` system account. The unit grants
only `CAP_NET_RAW` and `CAP_NET_ADMIN` to the capture process; it does not run
the capture as root. Root-only pre-start logic prepares the directory and
interface before dropping to the service account.

Capture files use timestamped names:

```text
/var/log/pcap/eth1-YYYYMMDD-HHMMSS.pcap
/var/log/pcap/eth1-YYYYMMDD-HHMMSS.pcap1
/var/log/pcap/eth1-YYYYMMDD-HHMMSS.pcap2
```

The timestamp is generated by `tcpdump` for each time rotation. A numeric suffix
is added when size rotation creates more than one file in the same time period.
Files therefore sort chronologically by their base name. Their timestamps use
the Raspberry Pi system clock; set the clock correctly when the Pi has neither
NTP synchronization nor a hardware RTC.

Default rotation and retention limits are:

```text
Rotate at 200 MB or after 24 hours
Keep the newest 10 managed files globally
About 2 GB maximum across service restarts
```

The retention helper removes only files matching the configured managed prefix;
it does not remove unrelated PCAP files. It reserves one slot before startup
and enforces the limit after rotations and stops, so restarting the service does
not create another independent 2 GB set. A rotation can briefly exceed the
limit while asynchronous cleanup completes.

With no cable and no traffic, the active PCAP normally contains only its capture
header and remains very small. A time rotation may produce another tiny file,
but the same 10-file limit applies. `tcpdump` is expected to remain active in
this state so it is ready for the first packets.

### Capture Control

Use the managed command instead of operating the unit directly:

```bash
sudo zero2w-capture status
sudo zero2w-capture enable
sudo zero2w-capture rotate
sudo zero2w-capture restart
sudo zero2w-capture disable
```

`enable` starts capture immediately and enables it at boot. `disable` stops it
and disables boot startup. `rotate` closes the current PCAP by restarting the
service and immediately starts a new timestamped file. To install the controls
without starting capture, provision with:

```bash
sudo ENABLE_CAPTURE=yes CAPTURE_AUTO_START=no ./configure-pi-router.sh
```

This opt-out is useful when capture must be started manually, but it cannot
capture packets sent before `zero2w-capture enable` completes.

Configuration is stored in `/etc/default/zero2w-capture`:

```bash
CAPTURE_INTERFACE=eth1
CAPTURE_DIRECTORY=/var/log/pcap
CAPTURE_FILE_PREFIX=eth1
CAPTURE_FILE_SIZE_MB=200
CAPTURE_MAX_FILES=10
CAPTURE_ROTATE_SECONDS=86400
CAPTURE_FILTER=""
```

`CAPTURE_FILTER` accepts a normal tcpdump/pcap filter, for example
`CAPTURE_FILTER="arp or (udp and (port 67 or port 68))"`. Restart capture after
editing the file:

```bash
sudo zero2w-capture restart
```

Useful commands:

```bash
sudo zero2w-capture status
sudo systemctl status eth1-capture.service --no-pager -l
sudo journalctl -u eth1-capture.service -b --no-pager
ip -br link show eth0 eth1
pgrep -a tcpdump
sudo ls -lh /var/log/pcap
sudo du -h /var/log/pcap
sudo tcpdump -nn -r /var/log/pcap/<capture-file>
sudo tcpdump -i eth1 -nn
```

The final command opens a second live listener for troubleshooting and does not
replace the service's PCAP writer.

## Transparent MITM

The optional MITM subsystem is intended only for authorized device and network
security assessments. It is not installed unless `ENABLE_MITM=yes` is supplied,
and interception is disabled by default after installation.

Normal/passive traffic remains:

```text
Device -> eth1 -> NetworkManager routing/NAT -> eth0
```

When enabled, only TCP entering through `eth1` is sent through the isolated
`ZERO2W_MITM` chain:

```text
eth1 TCP -> PREROUTING -> ZERO2W_MITM -> mitmdump:8080 -> original destination
```

The project does not replace NetworkManager routing or NAT, flush the NAT table,
or alter NetworkManager firewall rules. Management traffic entering through
`wlan0` and locally originated Raspberry Pi traffic never enter the project
jump. Router-local destinations and configured bypass CIDRs return from the
chain without interception.

### Modes

| Mode | Behavior |
| --- | --- |
| Passive/disabled | No redirect; NetworkManager routing and tcpdump continue normally |
| `web` | Redirect TCP ports 80 and 443 from `eth1` |
| `tcp` | Redirect all TCP from `eth1`; mitmproxy uses `tcp_hosts=.*` for generic TCP handling |

DNS, DHCP, NTP, ICMP, and all UDP traffic continue through normal routing in
both active modes. QUIC/HTTP3 (`UDP/443`), DTLS, and arbitrary UDP protocols are
not intercepted and remain visible only in the PCAP capture.

### Prerequisites

With `ENABLE_MITM=yes`, the provisioning script attempts to install the latest
official standalone Linux release matching the device architecture. Verify the
managed installation with:

```bash
/opt/zero2w-mitm/bin/mitmdump --version
cat /opt/zero2w-mitm/RELEASE
```

The installer queries `https://downloads.mitmproxy.org/list`, selects the newest
stable semantic version that has an archive for the current architecture, and
downloads it over HTTPS. If Internet is unavailable, it reuses an existing
managed or operator-configured `mitmdump`; otherwise MITM remains unavailable
without affecting routing.

The tested environment uses mitmproxy 12.2.x on Debian/Raspberry Pi OS aarch64.
The service runs as the dedicated unprivileged `zero2w-mitm` account. Root is
used only by the control and systemd lifecycle helpers for iptables and service
management.

NetworkManager shared mode normally enables IPv4 forwarding. Activation fails
safely with a diagnostic if this is not true:

```bash
sysctl net.ipv4.ip_forward
```

The prerequisite check also reports
`net.ipv4.conf.all.send_redirects`. It does not make a persistent global sysctl
change because this appliance routes device traffic from `eth1` to a different
interface (`eth0`), rather than forwarding it back through the same LAN.

### Installation And Control

Keep the repository's `mitm` directory beside `configure-pi-router.sh`, then
install the subsystem:

```bash
sudo ENABLE_MITM=yes ./configure-pi-router.sh
sudo zero2w-mitm status
```

Enable HTTP/HTTPS interception:

```bash
sudo zero2w-mitm enable web
```

Enable interception of all applicable TCP:

```bash
sudo zero2w-mitm enable tcp
```

Change mode or restart the current mode:

```bash
sudo zero2w-mitm enable web
sudo zero2w-mitm restart
```

Remove redirects first and stop the proxy without rebooting:

```bash
sudo zero2w-mitm disable
```

Status includes the configured mode, service and boot state, listener, LAN
interface, forwarding state, firewall packet/byte counters, flow directory,
certificate path, selected `mitmdump` binary, and installed version:

```bash
sudo zero2w-mitm status
sudo systemctl status zero2w-mitm.service
sudo journalctl -u zero2w-mitm.service -b --no-pager
```

Configuration is stored in `/etc/default/zero2w-mitm`. Important defaults are:

```bash
MITM_LAN_IF=eth1
MITM_LISTEN_HOST=10.0.0.1
MITM_PORT=8080
MITM_DEFAULT_MODE=web
MITM_FLOW_DIR=/var/log/mitmproxy
MITM_BYPASS_CIDRS="10.0.0.1/32 192.168.50.0/24"
```

After editing the configuration, apply it with:

```bash
sudo zero2w-mitm restart
```

### Flows, PCAP, And Certificates

mitmproxy streams flows to timestamped files:

```text
/var/log/mitmproxy/mitm-YYYYMMDD-HHMMSS.flows
```

The existing `eth1-capture.service` remains independent and continues writing
raw traffic to `/var/log/pcap`. An assessment can therefore retain both raw PCAP
and parsed mitmproxy flows.

The dedicated account has a stable mitmproxy state directory. Its generated CA
certificate is located at:

```text
/var/lib/zero2w-mitm/.mitmproxy/mitmproxy-ca-cert.pem
```

No target-side proxy setting is required when the Pi is already the target's
gateway. However, TLS plaintext is visible only when the target trusts the
mitmproxy CA or otherwise accepts the interception certificate. Normal CA
validation and certificate pinning can cause intercepted TLS connections to
fail. This project does not weaken validation, bypass pinning, modify a target,
or install a CA on a target automatically.

Timestamped artifacts use the Raspberry Pi system clock. A Pi without Internet
time synchronization or a hardware RTC must have its clock set during
provisioning if accurate timestamps are required.

### Failure Safety And Recovery

The systemd service starts `mitmdump` before adding the PREROUTING jump. On a
normal stop or unexpected service failure, both `ExecStop` and `ExecStopPost`
remove the project jump and chain. The operator `disable` command also removes
firewall redirects before stopping mitmproxy. Repeated enable and disable
operations are idempotent.

Verify cleanup after disabling:

```bash
sudo zero2w-mitm disable
sudo iptables -w 5 -t nat -C PREROUTING -i eth1 -p tcp \
  -m comment --comment zero2w-mitm -j ZERO2W_MITM
```

The final command should report that the rule does not exist. Normal
NetworkManager routing should continue immediately.

To remove the subsystem completely while preserving router configuration:

```bash
sudo zero2w-mitm disable
sudo rm -f /etc/systemd/system/zero2w-mitm.service
sudo rm -f /usr/local/sbin/zero2w-mitm
sudo rm -f /usr/local/libexec/zero2w-mitm-common
sudo rm -f /usr/local/libexec/zero2w-mitm-firewall
sudo rm -f /usr/local/libexec/zero2w-mitm-check
sudo rm -f /usr/local/libexec/zero2w-mitm-run
sudo rm -f /etc/default/zero2w-mitm
sudo systemctl daemon-reload
```

Flow files, the generated CA, and the dedicated system account are deliberately
left in place. Remove `/var/log/mitmproxy`, `/var/lib/zero2w-mitm`, and the
`zero2w-mitm` account separately only when those assessment artifacts and CA
state are no longer needed. The managed binaries under `/opt/zero2w-mitm` are
also retained unless explicitly removed with:

```bash
sudo rm -rf /opt/zero2w-mitm
```

## Tests

Run both static and mocked test suites from the repository root:

```bash
tests/test-zero2w-capture.sh
tests/test-zero2w-mitm.sh
```

The suites use mock `tcpdump`, `iptables`, `systemctl`, `sysctl`, and `mitmdump`
commands. They do not modify the development machine's firewall, interfaces, or
services.

## Verification

After running the script, check:

```bash
nmcli -t -f NAME,TYPE,AUTOCONNECT connection show
ip -4 addr show eth0
ip -4 addr show eth1
ip -4 addr show wlan0
ip -4 route
sudo cat /root/pi-router-wifi.txt
sudo zero2w-capture status
sudo zero2w-mitm status  # when installed with ENABLE_MITM=yes
```

Expected results:

- `WAN-ETH0`, `LAN-ETH1`, and `MGMT-WIFI` exist and autoconnect.
- `eth0` and `eth1` contain the `UP` flag, even if they also report
  `NO-CARRIER` while disconnected.
- `eth0` receives DHCP when an uplink network is available.
- `eth0` owns the default route.
- `eth1` has `10.0.0.1/24`.
- `wlan0` has `192.168.50.1/24`.
- The management AP SSID starts with `pi_`.
- The default management AP password matches the SSID unless it was manually
  changed with `set-pi-router-wifi-password.sh`.
- The credentials file is readable only by root.
- `zero2w-capture status` reports active and enabled when capture is enabled and
  `tcpdump` exists.
- `zero2w-mitm status` reports disabled after a default optional installation.

## Rollback

Disable packet capture:

```bash
sudo zero2w-capture disable
```

Disable transparent MITM before any broader rollback:

```bash
sudo zero2w-mitm disable
```

Remove the NetworkManager profiles created by the script:

```bash
sudo nmcli connection down MGMT-WIFI
sudo nmcli connection down LAN-ETH1
sudo nmcli connection down WAN-ETH0
sudo nmcli connection delete MGMT-WIFI
sudo nmcli connection delete LAN-ETH1
sudo nmcli connection delete WAN-ETH0
```

If a previous systemd capture service was backed up, restore it by copying the
desired backup over `/etc/systemd/system/eth1-capture.service` and reloading
systemd:

```bash
sudo systemctl daemon-reload
```

The script disables autoconnect on competing NetworkManager profiles instead of
deleting them. Re-enable any original profile manually if needed:

```bash
sudo nmcli connection modify <profile-name> connection.autoconnect yes
```
