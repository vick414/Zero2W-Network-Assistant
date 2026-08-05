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
- Optionally installs `tcpdump` when Internet/package repository access is
  available, then configures `eth1-capture.service`.

## Requirements

Essential commands must already be available:

```bash
bash nmcli ip systemctl readlink awk sed grep tr head cut cat chmod mkdir tee cp mv date
```

Optional commands:

- `tcpdump`: enables rotating packet capture on `eth1`. If missing, the script
  tries to install it with `apt-get` when repository access is available.
- `raspi-config` or `iw`: used when available to set the Wi-Fi country.
- `rfkill`: used when available to unblock Wi-Fi.

The script does not install NetworkManager or other required base tools. The only
package it may install is `tcpdump`, and only for packet capture.

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
```

Example:

```bash
sudo WIFI_COUNTRY=US AP_CHANNEL=6 ENABLE_CAPTURE=yes ./configure-pi-router.sh
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

If those commands fail, the script skips packet capture and continues.

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

If `tcpdump` is available or can be installed, the script creates:

```text
/etc/systemd/system/eth1-capture.service
/var/log/pcap
```

The service attaches `tcpdump` directly to `eth1` as soon as the interface exists.
This is intentional: it allows capture of the first DHCP, ARP, or other packets
immediately after link-up.

Capture files use timestamped names:

```text
/var/log/pcap/eth1-YYYYMMDD-HHMMSS.pcap
/var/log/pcap/eth1-YYYYMMDD-HHMMSS.pcap1
/var/log/pcap/eth1-YYYYMMDD-HHMMSS.pcap2
```

Rotation limits:

```text
200 MB per file
10 files maximum
About 2 GB total per capture-service run
```

With no cable connected and no traffic, the capture file should remain very
small. `tcpdump` is still expected to be running so it can capture the first
packets when a device is connected.

Useful commands:

```bash
systemctl status eth1-capture.service
systemctl cat eth1-capture.service
pgrep -a tcpdump
sudo ls -lh /var/log/pcap
sudo du -h /var/log/pcap
```

## Verification

After running the script, check:

```bash
nmcli -t -f NAME,TYPE,AUTOCONNECT connection show
ip -4 addr show eth0
ip -4 addr show eth1
ip -4 addr show wlan0
ip -4 route
sudo cat /root/pi-router-wifi.txt
systemctl status eth1-capture.service
```

Expected results:

- `WAN-ETH0`, `LAN-ETH1`, and `MGMT-WIFI` exist and autoconnect.
- `eth0` receives DHCP when an uplink network is available.
- `eth0` owns the default route.
- `eth1` has `10.0.0.1/24`.
- `wlan0` has `192.168.50.1/24`.
- The management AP SSID starts with `pi_`.
- The default management AP password matches the SSID unless it was manually
  changed with `set-pi-router-wifi-password.sh`.
- The credentials file is readable only by root.
- `eth1-capture.service` is active when capture is enabled and `tcpdump` exists.

## Rollback

Disable packet capture:

```bash
sudo systemctl disable --now eth1-capture.service
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
