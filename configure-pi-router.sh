#!/usr/bin/env bash
# Configure a Raspberry Pi OS system as a three-interface routed network appliance.
# This script is offline-safe for router setup; tcpdump may be installed when repositories are reachable.

set -Eeuo pipefail

trap 'rc=$?; printf "[ERROR] Failed at line %s while running: %s\n" "$LINENO" "$BASH_COMMAND" >&2; exit "$rc"' ERR

WAN_IF="eth0"
LAN_IF="eth1"
WIFI_IF="wlan0"

WAN_PROFILE="WAN-ETH0"
LAN_PROFILE="LAN-ETH1"
AP_PROFILE="MGMT-WIFI"

WIFI_COUNTRY="${WIFI_COUNTRY:-US}"
AP_CHANNEL="${AP_CHANNEL:-6}"
ENABLE_CAPTURE="${ENABLE_CAPTURE:-yes}"

MGMT_ADDRESS="192.168.50.1/24"
MGMT_IP="192.168.50.1"
MGMT_NETWORK="192.168.50.0/24"
MGMT_DHCP_RANGE="192.168.50.100,192.168.50.200"
MGMT_DHCP_RANGE_DISPLAY="192.168.50.100-192.168.50.200"

LAN_ADDRESS="10.0.0.1/24"
LAN_NETWORK="10.0.0.0/24"
LAN_DHCP_RANGE="10.0.0.100,10.0.0.250"
LAN_DHCP_RANGE_DISPLAY="10.0.0.100-10.0.0.250"

CREDENTIALS_FILE="/root/pi-router-wifi.txt"
LEGACY_INTERFACE_UP_SERVICE="/etc/systemd/system/pi-router-interfaces-up.service"
PCAP_DIRECTORY="/var/log/pcap"
CAPTURE_SERVICE="/etc/systemd/system/eth1-capture.service"
CAPTURE_HELPER="/usr/local/sbin/eth1-capture-start.sh"
PCAP_SIZE_MB="200"
PCAP_FILE_COUNT="10"

CAPTURE_STATUS="disabled"

info() {
    printf '[INFO] %s\n' "$*"
}

ok() {
    printf '[OK] %s\n' "$*"
}

warn() {
    printf '[WARNING] %s\n' "$*" >&2
}

fail() {
    printf '[ERROR] %s\n' "$*" >&2
    exit 1
}

usage() {
    cat <<'EOF_HELP'
Usage:
  sudo ./configure-pi-router.sh
  ./configure-pi-router.sh --help

Architecture:
  eth0  -> DHCP WAN/uplink. This interface is intended to own the IPv4 default route.
  eth1  -> 10.0.0.1/24 routed device LAN with DHCP, DNS forwarding, and NAT.
  wlan0 -> 192.168.50.1/24 management Wi-Fi access point with DHCP.

The three networks remain separate routed networks. The script does not create a
Layer 2 bridge.

Offline behavior:
  This script is designed to complete the main router configuration without
  Internet access. NetworkManager and the required base commands must already be
  present. If packet capture is enabled, tcpdump is missing, apt-get exists, and
  package repositories are reachable, the script attempts to install tcpdump.
  If that install attempt fails, packet capture is skipped and router setup
  continues.

Environment overrides:
  WIFI_COUNTRY=US       Wi-Fi regulatory country used when supported.
  AP_CHANNEL=6          2.4 GHz access point channel.
  ENABLE_CAPTURE=yes    Set to "no" to skip the optional eth1 tcpdump service.

Created or updated NetworkManager profiles:
  WAN-ETH0   Bound to eth0, IPv4 DHCP, default route allowed, route metric 100.
  LAN-ETH1   Bound to eth1, IPv4 shared mode, 10.0.0.1/24, no default route.
  MGMT-WIFI  Bound to wlan0, AP mode, WPA2-PSK, 192.168.50.1/24, no default route.

Created or updated files:
  /root/pi-router-wifi.txt
  /etc/systemd/system/eth1-capture.service, only when tcpdump is available and capture is enabled.
  /var/log/pcap, only when packet capture is configured.

Default Wi-Fi credentials:
  The SSID is generated from the last three bytes of the wlan0 MAC address, for
  example pi_A1B2C3. The default password is the same value as the SSID because
  WPA2 requires at least 8 characters. A manual password stored with
  set-pi-router-wifi-password.sh is preserved on later runs.

Notes:
  A temporary network interruption is possible while NetworkManager profiles are
  changed and reactivated. Missing optional tools such as tcpdump are reported as
  warnings and do not stop the main router configuration.
EOF_HELP
}

require_root() {
    [[ "${EUID}" -eq 0 ]] || fail "Run this script as root: sudo ./configure-pi-router.sh"
}

require_command() {
    local command_name="$1"
    command -v "$command_name" >/dev/null 2>&1 || fail "Required command '$command_name' is missing. Install it before running this script. Only tcpdump can be installed automatically, and only when packet capture is enabled and package repositories are reachable."
}

require_base_commands() {
    local required_commands=(
        bash nmcli ip systemctl readlink awk sed grep tr head cut cat chmod mkdir tee cp mv rm date
    )
    local command_name

    for command_name in "${required_commands[@]}"; do
        require_command "$command_name"
    done
}

service_exists() {
    local service_name="$1"
    systemctl list-unit-files "$service_name" --no-legend 2>/dev/null | grep -q .
}

ensure_networkmanager() {
    if ! service_exists "NetworkManager.service"; then
        fail "NetworkManager.service is not installed. NetworkManager must already be installed and enabled."
    fi

    if systemctl is-active --quiet NetworkManager.service; then
        ok "NetworkManager is running."
        return 0
    fi

    info "Starting NetworkManager.service."
    systemctl start NetworkManager.service
    systemctl is-active --quiet NetworkManager.service || fail "NetworkManager.service could not be started."
}

enable_ssh_if_available() {
    local ssh_service=""

    if service_exists "ssh.service"; then
        ssh_service="ssh.service"
    elif service_exists "sshd.service"; then
        ssh_service="sshd.service"
    else
        warn "No ssh.service or sshd.service was found. SSH was not enabled."
        return 0
    fi

    info "Enabling and starting $ssh_service."
    systemctl enable --now "$ssh_service" >/dev/null 2>&1 || warn "Could not enable and start $ssh_service."
}

check_interface() {
    local interface_name="$1"
    [[ -d "/sys/class/net/$interface_name" ]] || fail "Interface '$interface_name' was not found."
}

set_managed_interface() {
    local interface_name="$1"
    nmcli device set "$interface_name" managed yes
}

bring_interface_up() {
    local interface_name="$1"
    ip link set "$interface_name" up >/dev/null 2>&1 || warn "Could not force $interface_name administratively up; NetworkManager will still try to activate it."
}

remove_legacy_interface_up_service() {
    if [[ ! -f "$LEGACY_INTERFACE_UP_SERVICE" ]]; then
        return 0
    fi

    if ! grep -Fq 'Description=Keep Raspberry Pi router Ethernet interfaces administratively up' "$LEGACY_INTERFACE_UP_SERVICE"; then
        warn "Found $LEGACY_INTERFACE_UP_SERVICE, but it was not created by this script; leaving it unchanged."
        return 0
    fi

    systemctl disable --now pi-router-interfaces-up.service >/dev/null 2>&1 || true
    rm -f "$LEGACY_INTERFACE_UP_SERVICE"
    systemctl daemon-reload
    ok "Removed the obsolete pi-router-interfaces-up.service."
}

normalize_enable_capture() {
    case "$ENABLE_CAPTURE" in
        yes|YES|true|TRUE|1) ENABLE_CAPTURE="yes" ;;
        no|NO|false|FALSE|0) ENABLE_CAPTURE="no" ;;
        *) fail "ENABLE_CAPTURE must be yes or no." ;;
    esac
}

validate_wifi_country_and_channel() {
    [[ "$WIFI_COUNTRY" =~ ^[A-Za-z]{2}$ ]] || fail "WIFI_COUNTRY must be a two-letter country code."
    WIFI_COUNTRY="$(printf '%s' "$WIFI_COUNTRY" | tr '[:lower:]' '[:upper:]')"

    [[ "$AP_CHANNEL" =~ ^[0-9]+$ ]] || fail "AP_CHANNEL must be a numeric 2.4 GHz Wi-Fi channel."
    if (( AP_CHANNEL < 1 || AP_CHANNEL > 14 )); then
        fail "AP_CHANNEL must be between 1 and 14 for 2.4 GHz operation."
    fi
}

valid_mac() {
    local value="$1"
    [[ "$value" =~ ^([[:xdigit:]]{2}:){5}[[:xdigit:]]{2}$ ]]
}

detect_wlan_mac() {
    local permanent_file="/sys/class/net/$WIFI_IF/perm_address"
    local current_file="/sys/class/net/$WIFI_IF/address"
    local mac=""

    if [[ -r "$permanent_file" ]]; then
        mac="$(head -n 1 "$permanent_file" | tr '[:lower:]' '[:upper:]' || true)"
    fi

    if ! valid_mac "$mac" && [[ -r "$current_file" ]]; then
        mac="$(head -n 1 "$current_file" | tr '[:lower:]' '[:upper:]' || true)"
    fi

    valid_mac "$mac" || fail "Could not determine a valid MAC address for $WIFI_IF."
    printf '%s\n' "$mac"
}

ssid_from_mac() {
    local mac="$1"
    local compact=""
    compact="$(printf '%s' "$mac" | tr -d ':' | tr '[:lower:]' '[:upper:]')"
    printf 'pi_%s\n' "$(printf '%s' "$compact" | cut -c 7-12)"
}

valid_wifi_password() {
    local value="$1"
    local length="${#value}"

    (( length >= 8 && length <= 63 )) || return 1
    [[ "$value" =~ ^[[:graph:]]+$ ]]
}

read_saved_value() {
    local key="$1"
    local file="$2"
    awk -F= -v wanted="$key" '$1 == wanted {print substr($0, index($0, "=") + 1); exit}' "$file"
}

load_or_create_credentials() {
    local ssid="$1"
    local default_password="$ssid"
    local saved_ssid=""
    local saved_password=""
    local saved_source=""
    local password=""
    local temporary_file=""

    if [[ -r "$CREDENTIALS_FILE" ]]; then
        saved_ssid="$(read_saved_value "SSID" "$CREDENTIALS_FILE" || true)"
        saved_password="$(read_saved_value "PASSWORD" "$CREDENTIALS_FILE" || true)"
        saved_source="$(read_saved_value "PASSWORD_SOURCE" "$CREDENTIALS_FILE" || true)"
        if [[ "$saved_ssid" == "$ssid" ]] && valid_wifi_password "$saved_password" && [[ "$saved_source" == "manual" ]]; then
            chmod 600 "$CREDENTIALS_FILE"
            printf '%s\n' "$saved_password"
            return 0
        fi
        if [[ "$saved_ssid" == "$ssid" && "$saved_password" == "$default_password" ]]; then
            chmod 600 "$CREDENTIALS_FILE"
            printf '%s\n' "$saved_password"
            return 0
        fi
        warn "$CREDENTIALS_FILE does not contain the current default or a manual password for this SSID. The default MAC-based password will be written."
    fi

    password="$default_password"
    valid_wifi_password "$password" || fail "Default Wi-Fi password did not pass validation."

    temporary_file="${CREDENTIALS_FILE}.$$"
    {
        printf 'SSID=%s\n' "$ssid"
        printf 'PASSWORD=%s\n' "$password"
        printf 'PASSWORD_SOURCE=default\n'
        printf 'MANAGEMENT_IP=%s\n' "$MGMT_IP"
    } | tee "$temporary_file" >/dev/null
    chmod 600 "$temporary_file"
    mv "$temporary_file" "$CREDENTIALS_FILE"
    chmod 600 "$CREDENTIALS_FILE"

    printf '%s\n' "$password"
}

connection_exists() {
    local profile_name="$1"
    nmcli connection show "$profile_name" >/dev/null 2>&1
}

disable_competing_profiles() {
    local interface_name="$1"
    local keep_profile="$2"
    local uuid=""
    local profile_name=""
    local bound_if=""
    local connection_type=""
    local active_connection=""
    local should_disable=""

    active_connection="$(nmcli -g GENERAL.CONNECTION device show "$interface_name" 2>/dev/null | head -n 1 || true)"

    while IFS= read -r uuid; do
        [[ -n "$uuid" ]] || continue
        profile_name="$(nmcli -g connection.id connection show "$uuid" 2>/dev/null | head -n 1 || true)"
        bound_if="$(nmcli -g connection.interface-name connection show "$uuid" 2>/dev/null | head -n 1 || true)"
        connection_type="$(nmcli -g connection.type connection show "$uuid" 2>/dev/null | head -n 1 || true)"

        if [[ "$profile_name" == "$keep_profile" ]]; then
            continue
        fi

        should_disable="no"
        if [[ "$bound_if" == "$interface_name" || "$profile_name" == "$active_connection" ]]; then
            should_disable="yes"
        elif [[ "$interface_name" == "$WIFI_IF" && -z "$bound_if" && "$connection_type" == "802-11-wireless" ]]; then
            should_disable="yes"
        elif [[ "$connection_type" == "802-3-ethernet" && "$profile_name" == *"$interface_name"* ]]; then
            should_disable="yes"
        fi

        if [[ "$should_disable" == "yes" ]]; then
            warn "Disabling autoconnect for competing profile '$profile_name' on $interface_name."
            nmcli connection modify "$uuid" connection.autoconnect no >/dev/null 2>&1 || true
            if [[ "$profile_name" == "$active_connection" && -n "$profile_name" && "$profile_name" != "--" ]]; then
                nmcli connection down "$uuid" >/dev/null 2>&1 || true
            fi
        fi
    done < <(nmcli -t -f UUID connection show)
}

configure_optional_dhcp_range() {
    local profile_name="$1"
    local dhcp_range="$2"

    if nmcli -f ipv4.shared-dhcp-range connection show "$profile_name" >/dev/null 2>&1; then
        nmcli connection modify "$profile_name" ipv4.shared-dhcp-range "$dhcp_range"
    else
        warn "This NetworkManager version does not expose ipv4.shared-dhcp-range for '$profile_name'. NetworkManager will choose a DHCP range inside the configured subnet."
    fi
}

ensure_wan_profile() {
    info "Configuring $WAN_IF as the DHCP WAN interface."
    disable_competing_profiles "$WAN_IF" "$WAN_PROFILE"

    if ! connection_exists "$WAN_PROFILE"; then
        nmcli connection add type ethernet ifname "$WAN_IF" con-name "$WAN_PROFILE" >/dev/null
    fi

    nmcli connection modify "$WAN_PROFILE" \
        connection.interface-name "$WAN_IF" \
        connection.autoconnect yes \
        connection.autoconnect-priority 999 \
        ipv4.method auto \
        ipv4.never-default no \
        ipv4.route-metric 100 \
        ipv6.method disabled

    if nmcli connection up "$WAN_PROFILE" ifname "$WAN_IF" >/dev/null 2>&1; then
        ok "$WAN_PROFILE is active."
    else
        warn "$WAN_PROFILE was configured, but $WAN_IF did not activate or receive DHCP yet."
    fi
}

ensure_lan_profile() {
    info "Configuring $LAN_IF as the routed device LAN."
    disable_competing_profiles "$LAN_IF" "$LAN_PROFILE"

    if ! connection_exists "$LAN_PROFILE"; then
        nmcli connection add type ethernet ifname "$LAN_IF" con-name "$LAN_PROFILE" >/dev/null
    fi

    nmcli connection modify "$LAN_PROFILE" \
        connection.interface-name "$LAN_IF" \
        connection.autoconnect yes \
        connection.autoconnect-priority 900 \
        ipv4.method shared \
        ipv4.addresses "$LAN_ADDRESS" \
        ipv4.never-default yes \
        ipv4.route-metric 800 \
        ipv6.method disabled

    configure_optional_dhcp_range "$LAN_PROFILE" "$LAN_DHCP_RANGE"
    nmcli connection up "$LAN_PROFILE" ifname "$LAN_IF" >/dev/null
    ok "$LAN_PROFILE is active."
}

ensure_wifi_profile() {
    local ssid="$1"
    local password="$2"
    local ap_supported=""

    info "Configuring $WIFI_IF as the management Wi-Fi access point."
    nmcli radio wifi on >/dev/null 2>&1 || warn "Could not enable the NetworkManager Wi-Fi radio."

    if command -v rfkill >/dev/null 2>&1; then
        rfkill unblock wifi >/dev/null 2>&1 || warn "Could not unblock Wi-Fi with rfkill."
    fi

    if command -v raspi-config >/dev/null 2>&1; then
        raspi-config nonint do_wifi_country "$WIFI_COUNTRY" >/dev/null 2>&1 || warn "Could not set Wi-Fi country with raspi-config."
    elif command -v iw >/dev/null 2>&1; then
        iw reg set "$WIFI_COUNTRY" >/dev/null 2>&1 || warn "Could not set Wi-Fi country with iw."
    else
        warn "Neither raspi-config nor iw is available; Wi-Fi country was not applied."
    fi

    ap_supported="$(nmcli -g WIFI-PROPERTIES.AP device show "$WIFI_IF" 2>/dev/null | head -n 1 || true)"
    if [[ "$ap_supported" != "yes" ]]; then
        fail "$WIFI_IF does not report access point support through NetworkManager. Detected value: ${ap_supported:-unknown}."
    fi

    disable_competing_profiles "$WIFI_IF" "$AP_PROFILE"

    if ! connection_exists "$AP_PROFILE"; then
        nmcli connection add type wifi ifname "$WIFI_IF" con-name "$AP_PROFILE" ssid "$ssid" >/dev/null
    fi

    nmcli connection modify "$AP_PROFILE" \
        connection.interface-name "$WIFI_IF" \
        connection.autoconnect yes \
        connection.autoconnect-priority 950 \
        802-11-wireless.ssid "$ssid" \
        802-11-wireless.mode ap \
        802-11-wireless.band bg \
        802-11-wireless.channel "$AP_CHANNEL" \
        802-11-wireless.hidden no \
        802-11-wireless-security.key-mgmt wpa-psk \
        802-11-wireless-security.proto rsn \
        802-11-wireless-security.pairwise ccmp \
        802-11-wireless-security.psk "$password" \
        ipv4.method shared \
        ipv4.addresses "$MGMT_ADDRESS" \
        ipv4.never-default yes \
        ipv4.route-metric 900 \
        ipv6.method disabled

    configure_optional_dhcp_range "$AP_PROFILE" "$MGMT_DHCP_RANGE"
    nmcli connection up "$AP_PROFILE" ifname "$WIFI_IF" >/dev/null
    ok "$AP_PROFILE is active."
}

ip_to_int() {
    local ip_address="$1"
    local o1="" o2="" o3="" o4=""
    IFS=. read -r o1 o2 o3 o4 <<< "$ip_address"
    printf '%u\n' $(( (o1 << 24) + (o2 << 16) + (o3 << 8) + o4 ))
}

cidr_network_int() {
    local cidr="$1"
    local ip_part="${cidr%/*}"
    local prefix="${cidr#*/}"
    local ip_int=""
    local mask=""

    ip_int="$(ip_to_int "$ip_part")"
    if (( prefix == 0 )); then
        mask=0
    else
        mask=$(( (0xFFFFFFFF << (32 - prefix)) & 0xFFFFFFFF ))
    fi

    printf '%u %u\n' "$(( ip_int & mask ))" "$mask"
}

cidr_overlaps() {
    local cidr_a="$1"
    local cidr_b="$2"
    local net_a="" mask_a="" net_b="" mask_b=""
    read -r net_a mask_a < <(cidr_network_int "$cidr_a")
    read -r net_b mask_b < <(cidr_network_int "$cidr_b")

    [[ "$(( net_a & mask_b ))" -eq "$net_b" && "$(( net_b & mask_a ))" -eq "$net_a" ]]
}

check_wan_overlap() {
    local wan_cidr=""

    wan_cidr="$(ip -4 -o address show dev "$WAN_IF" scope global 2>/dev/null | awk 'NR == 1 {print $4}')"
    if [[ -z "$wan_cidr" ]]; then
        warn "$WAN_IF does not currently have a DHCP IPv4 address. The router configuration is complete, but WAN lease validation is pending."
        return 0
    fi

    if cidr_overlaps "$wan_cidr" "$MGMT_NETWORK"; then
        warn "The WAN address $wan_cidr overlaps with $MGMT_NETWORK. Use a different upstream network or change the management subnet."
    fi

    if cidr_overlaps "$wan_cidr" "$LAN_NETWORK"; then
        warn "The WAN address $wan_cidr overlaps with $LAN_NETWORK. Use a different upstream network or change the device LAN subnet."
    fi
}

install_tcpdump_if_online() {
    if command -v tcpdump >/dev/null 2>&1; then
        return 0
    fi

    if ! command -v apt-get >/dev/null 2>&1; then
        warn "tcpdump is not installed and apt-get is unavailable. Packet capture service will be skipped."
        return 1
    fi

    if ! ip -4 route show default >/dev/null 2>&1 || [[ -z "$(ip -4 route show default 2>/dev/null | head -n 1)" ]]; then
        warn "tcpdump is not installed and no IPv4 default route is currently available. Packet capture service will be skipped."
        return 1
    fi

    info "tcpdump is not installed. Attempting to install it because a default route is available."
    if ! apt-get \
        -o Acquire::Retries=0 \
        -o Acquire::http::Timeout=10 \
        -o Acquire::https::Timeout=10 \
        update; then
        warn "apt-get update failed. Internet or package repositories are unavailable. Packet capture service will be skipped."
        return 1
    fi

    if ! apt-get \
        -o Acquire::Retries=0 \
        -o Acquire::http::Timeout=10 \
        -o Acquire::https::Timeout=10 \
        install -y tcpdump; then
        warn "apt-get install tcpdump failed. Packet capture service will be skipped."
        return 1
    fi

    command -v tcpdump >/dev/null 2>&1 || {
        warn "tcpdump installation completed but tcpdump is still not available in PATH. Packet capture service will be skipped."
        return 1
    }

    ok "tcpdump installed."
    return 0
}

configure_capture_service() {
    local bash_path=""
    local tcpdump_path=""
    local timestamp=""
    local temporary_helper=""
    local temporary_service=""

    if [[ "$ENABLE_CAPTURE" == "no" ]]; then
        CAPTURE_STATUS="disabled"
        if service_exists "eth1-capture.service"; then
            systemctl disable --now eth1-capture.service >/dev/null 2>&1 || true
        fi
        ok "Packet capture is disabled by ENABLE_CAPTURE=no."
        return 0
    fi

    if ! command -v tcpdump >/dev/null 2>&1 && ! install_tcpdump_if_online; then
        CAPTURE_STATUS="skipped because tcpdump is unavailable"
        warn "tcpdump is unavailable. Packet capture service was skipped."
        return 0
    fi

    bash_path="$(command -v bash)"
    tcpdump_path="$(command -v tcpdump)"
    mkdir -p "/usr/local/sbin"
    mkdir -p "$PCAP_DIRECTORY"
    chmod 700 "$PCAP_DIRECTORY"

    temporary_helper="${CAPTURE_HELPER}.$$"
    {
        printf '#!%s\n' "$bash_path"
        printf 'set -Eeuo pipefail\n'
        printf '\n'
        printf 'exec %q -i %q -nn -s 0 -U -C %q -W %q -Z root -w %q/eth1-$(date +%%Y%%m%%d-%%H%%M%%S).pcap\n' "$tcpdump_path" "$LAN_IF" "$PCAP_SIZE_MB" "$PCAP_FILE_COUNT" "$PCAP_DIRECTORY"
    } | tee "$temporary_helper" >/dev/null
    chmod 755 "$temporary_helper"
    mv "$temporary_helper" "$CAPTURE_HELPER"

    if [[ -f "$CAPTURE_SERVICE" ]]; then
        timestamp="$(date '+%Y%m%d-%H%M%S')"
        cp "$CAPTURE_SERVICE" "${CAPTURE_SERVICE}.backup-${timestamp}"
        chmod 600 "${CAPTURE_SERVICE}.backup-${timestamp}"
        ok "Backed up existing eth1-capture.service."
    fi

    temporary_service="${CAPTURE_SERVICE}.$$"
    {
        printf '[Unit]\n'
        printf 'Description=Rotating packet capture on %s\n' "$LAN_IF"
        printf 'BindsTo=sys-subsystem-net-devices-%s.device\n' "$LAN_IF"
        printf 'After=sys-subsystem-net-devices-%s.device NetworkManager.service\n' "$LAN_IF"
        printf 'ConditionPathExists=/sys/class/net/%s\n' "$LAN_IF"
        printf '\n[Service]\n'
        printf 'Type=simple\n'
        printf 'ExecStartPre=%s link set dev %s up\n' "$(command -v ip)" "$LAN_IF"
        printf 'ExecStart=%s\n' "$CAPTURE_HELPER"
        printf 'Restart=on-failure\n'
        printf 'RestartSec=5\n'
        printf '\n[Install]\n'
        printf 'WantedBy=multi-user.target\n'
        printf 'WantedBy=sys-subsystem-net-devices-%s.device\n' "$LAN_IF"
    } | tee "$temporary_service" >/dev/null
    chmod 644 "$temporary_service"
    mv "$temporary_service" "$CAPTURE_SERVICE"

    systemctl daemon-reload
    if systemctl enable --now eth1-capture.service >/dev/null 2>&1; then
        CAPTURE_STATUS="enabled"
        ok "Packet capture service is enabled."
    else
        CAPTURE_STATUS="configured but not running"
        warn "Packet capture service was written, but systemctl could not enable or start it."
    fi
}

default_route_summary() {
    ip -4 route show default 2>/dev/null | head -n 1
}

wan_address_summary() {
    local address=""
    address="$(ip -4 -o address show dev "$WAN_IF" scope global 2>/dev/null | awk 'NR == 1 {print $4}')"
    if [[ -n "$address" ]]; then
        printf '%s\n' "$address"
    else
        printf 'not currently assigned\n'
    fi
}

ssh_user_summary() {
    if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
        printf '%s\n' "$SUDO_USER"
    else
        printf '<user>\n'
    fi
}

print_summary() {
    local ssid="$1"
    local password="$2"
    local wan_address=""
    local default_route=""
    local ssh_user=""

    wan_address="$(wan_address_summary)"
    default_route="$(default_route_summary)"
    [[ -n "$default_route" ]] || default_route="not currently available"
    ssh_user="$(ssh_user_summary)"

    cat <<EOF_SUMMARY

Configuration completed.

Management Wi-Fi:
  Interface: $WIFI_IF
  SSID: $ssid
  Password: $password
  Raspberry Pi address: $MGMT_ADDRESS
  DHCP range: $MGMT_DHCP_RANGE_DISPLAY
  SSH command: ssh $ssh_user@$MGMT_IP

Device LAN:
  Interface: $LAN_IF
  Raspberry Pi address: $LAN_ADDRESS
  DHCP range: $LAN_DHCP_RANGE_DISPLAY
  Upstream interface: $WAN_IF

WAN:
  Interface: $WAN_IF
  Address: $wan_address
  Default route: $default_route

Packet capture:
  Status: $CAPTURE_STATUS
  Directory: $PCAP_DIRECTORY

Credentials file:
  $CREDENTIALS_FILE
EOF_SUMMARY
}

main() {
    local wlan_mac=""
    local ssid=""
    local wifi_password=""

    if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
        usage
        exit 0
    fi

    if [[ "$#" -gt 0 ]]; then
        usage >&2
        fail "Unsupported argument: $1"
    fi

    require_root
    normalize_enable_capture
    validate_wifi_country_and_channel
    require_base_commands

    check_interface "$WAN_IF"
    check_interface "$LAN_IF"
    check_interface "$WIFI_IF"

    ensure_networkmanager
    enable_ssh_if_available

    set_managed_interface "$WAN_IF"
    set_managed_interface "$LAN_IF"
    set_managed_interface "$WIFI_IF"
    bring_interface_up "$WAN_IF"
    bring_interface_up "$LAN_IF"
    bring_interface_up "$WIFI_IF"

    wlan_mac="$(detect_wlan_mac)"
    ssid="$(ssid_from_mac "$wlan_mac")"
    wifi_password="$(load_or_create_credentials "$ssid")"

    info "Detected $WIFI_IF MAC address $wlan_mac; management SSID will be $ssid."

    ensure_wan_profile
    check_wan_overlap
    ensure_lan_profile
    ensure_wifi_profile "$ssid" "$wifi_password"
    remove_legacy_interface_up_service
    configure_capture_service
    check_wan_overlap

    print_summary "$ssid" "$wifi_password"
}

main "$@"
