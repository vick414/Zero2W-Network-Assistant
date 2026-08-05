#!/usr/bin/env bash
# Change the management Wi-Fi password for the Raspberry Pi router profile.

set -Eeuo pipefail

trap 'rc=$?; printf "[ERROR] Failed at line %s while running: %s\n" "$LINENO" "$BASH_COMMAND" >&2; exit "$rc"' ERR

WIFI_IF="wlan0"
AP_PROFILE="MGMT-WIFI"
MGMT_IP="192.168.50.1"
CREDENTIALS_FILE="/root/pi-router-wifi.txt"

info() {
    printf '[INFO] %s\n' "$*"
}

ok() {
    printf '[OK] %s\n' "$*"
}

fail() {
    printf '[ERROR] %s\n' "$*" >&2
    exit 1
}

usage() {
    cat <<'EOF_HELP'
Usage:
  sudo ./set-pi-router-wifi-password.sh

This script changes the WPA2 password for the NetworkManager profile named
MGMT-WIFI. It prompts for the new password twice, validates that both entries
match, updates /root/pi-router-wifi.txt, and restarts the Wi-Fi access point
profile so the new password takes effect.

Password rules:
  8 to 63 printable non-space characters.

Warning:
  Restarting MGMT-WIFI disconnects current Wi-Fi management clients.
EOF_HELP
}

require_root() {
    [[ "$EUID" -eq 0 ]] || fail "Run this script as root: sudo ./set-pi-router-wifi-password.sh"
}

require_command() {
    local command_name="$1"
    command -v "$command_name" >/dev/null 2>&1 || fail "Required command '$command_name' is missing."
}

require_commands() {
    local required_commands=(bash nmcli awk head tr cut cat chmod tee mv)
    local command_name

    for command_name in "${required_commands[@]}"; do
        require_command "$command_name"
    done
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

prompt_password() {
    local first_password=""
    local second_password=""

    printf 'New Wi-Fi password: ' >&2
    IFS= read -r -s first_password
    printf '\n' >&2

    printf 'Repeat new Wi-Fi password: ' >&2
    IFS= read -r -s second_password
    printf '\n' >&2

    [[ "$first_password" == "$second_password" ]] || fail "The two password entries do not match."
    valid_wifi_password "$first_password" || fail "Password must be 8 to 63 printable non-space characters."

    printf '%s\n' "$first_password"
}

write_credentials() {
    local ssid="$1"
    local password="$2"
    local temporary_file=""

    temporary_file="${CREDENTIALS_FILE}.$$"
    {
        printf 'SSID=%s\n' "$ssid"
        printf 'PASSWORD=%s\n' "$password"
        printf 'PASSWORD_SOURCE=manual\n'
        printf 'MANAGEMENT_IP=%s\n' "$MGMT_IP"
    } | tee "$temporary_file" >/dev/null
    chmod 600 "$temporary_file"
    mv "$temporary_file" "$CREDENTIALS_FILE"
    chmod 600 "$CREDENTIALS_FILE"
}

restart_wifi_profile() {
    nmcli connection show "$AP_PROFILE" >/dev/null 2>&1 || fail "NetworkManager profile '$AP_PROFILE' was not found. Run configure-pi-router.sh first."
    nmcli connection modify "$AP_PROFILE" 802-11-wireless-security.psk "$1"

    info "Restarting $AP_PROFILE. Current Wi-Fi management clients will disconnect."
    nmcli connection down "$AP_PROFILE" >/dev/null 2>&1 || true
    nmcli connection up "$AP_PROFILE" ifname "$WIFI_IF" >/dev/null
}

main() {
    local wlan_mac=""
    local ssid=""
    local password=""

    if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
        usage
        exit 0
    fi

    [[ "$#" -eq 0 ]] || fail "Unsupported argument: $1"

    require_root
    require_commands

    [[ -d "/sys/class/net/$WIFI_IF" ]] || fail "Interface '$WIFI_IF' was not found."

    wlan_mac="$(detect_wlan_mac)"
    ssid="$(ssid_from_mac "$wlan_mac")"
    password="$(prompt_password)"

    write_credentials "$ssid" "$password"
    restart_wifi_profile "$password"

    ok "Management Wi-Fi password updated."
    printf 'SSID: %s\n' "$ssid"
    printf 'Credentials file: %s\n' "$CREDENTIALS_FILE"
}

main "$@"
