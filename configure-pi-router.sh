#!/usr/bin/env bash
# Configura una Raspberry Pi OS de 64 bits como router de tres interfaces:
#   wlan0 -> AP de management 192.168.50.1/24
#   eth1  -> LAN de dispositivos 10.0.0.1/24
#   eth0  -> WAN/uplink mediante DHCP
#
# Además, activa una captura circular del tráfico que entra/sale por eth1.
# Ejecutar como root: sudo ./configure-pi-router.sh

set -Eeuo pipefail

trap 'printf "\nERROR: fallo en la línea %s ejecutando: %s\n" "$LINENO" "$BASH_COMMAND" >&2' ERR

WAN_IF="${WAN_IF:-eth0}"
LAN_IF="${LAN_IF:-eth1}"
WIFI_IF="${WIFI_IF:-wlan0}"
WIFI_COUNTRY="${WIFI_COUNTRY:-US}"

WAN_PROFILE="WAN-ETH0"
LAN_PROFILE="LAN-ETH1"
AP_PROFILE="MGMT-WIFI"

MGMT_ADDRESS="192.168.50.1/24"
MGMT_NETWORK="192.168.50.0/24"
MGMT_DHCP_RANGE="192.168.50.100,192.168.50.200"

LAN_ADDRESS="10.0.0.1/24"
LAN_NETWORK="10.0.0.0/24"
LAN_DHCP_RANGE="10.0.0.100,10.0.0.250"

AP_CHANNEL="${AP_CHANNEL:-6}"
ENABLE_CAPTURE="${ENABLE_CAPTURE:-yes}"
PCAP_DIRECTORY="/var/log/pcap"
PCAP_SIZE_MB="${PCAP_SIZE_MB:-50}"
PCAP_FILE_COUNT="${PCAP_FILE_COUNT:-10}"
CREDENTIALS_FILE="/root/pi-router-wifi.txt"

log() {
    printf '\n==> %s\n' "$*"
}

fail() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

connection_exists() {
    nmcli -t -f NAME connection show | grep -Fqx -- "$1"
}

remove_profile() {
    local profile="$1"
    if connection_exists "$profile"; then
        nmcli connection delete "$profile" >/dev/null
    fi
}

disable_current_profile() {
    local interface="$1"
    local replacement="$2"
    local current=""

    current="$(nmcli -g GENERAL.CONNECTION device show "$interface" 2>/dev/null || true)"
    if [[ -n "$current" && "$current" != "--" && "$current" != "$replacement" ]]; then
        nmcli connection modify "$current" connection.autoconnect no 2>/dev/null || true
    fi
}

configure_optional_dhcp_range() {
    local profile="$1"
    local range="$2"

    # shared-dhcp-range no existe en algunas versiones antiguas de NetworkManager.
    # Si está disponible, fija el rango; si no, NetworkManager elige uno dentro
    # de la subred configurada.
    if nmcli -f ipv4.shared-dhcp-range connection show "$profile" >/dev/null 2>&1; then
        nmcli connection modify "$profile" ipv4.shared-dhcp-range "$range"
    fi
}

check_interface() {
    [[ -d "/sys/class/net/$1" ]] || fail "No existe la interfaz $1. Interfaces detectadas: $(ls /sys/class/net | tr '\n' ' ')"
}

check_wan_overlap() {
    local wan_cidr=""

    wan_cidr="$(ip -4 -o address show dev "$WAN_IF" scope global | awk 'NR == 1 {print $4}')"
    if [[ -z "$wan_cidr" ]]; then
        printf 'AVISO: %s todavía no ha recibido una dirección DHCP.\n' "$WAN_IF"
        printf 'Comprueba después que su red no coincida con %s ni %s.\n' "$MGMT_NETWORK" "$LAN_NETWORK"
        return 0
    fi

    if ! python3 - "$wan_cidr" "$MGMT_NETWORK" "$LAN_NETWORK" <<'PY'
import ipaddress
import sys

wan = ipaddress.ip_interface(sys.argv[1]).network
internal = [ipaddress.ip_network(value) for value in sys.argv[2:]]
conflicts = [str(network) for network in internal if wan.overlaps(network)]

if conflicts:
    print(
        f"ERROR: la red WAN {wan} se solapa con " + ", ".join(conflicts),
        file=sys.stderr,
    )
    raise SystemExit(1)

print(f"Red WAN detectada: {wan}; no existen solapamientos.")
PY
    then
        fail "Cambia las subredes internas o conecta $WAN_IF a una red diferente."
    fi
}

if [[ "$EUID" -ne 0 ]]; then
    fail "Ejecuta el script como root: sudo $0"
fi

export DEBIAN_FRONTEND=noninteractive

log "Instalando los paquetes necesarios"
apt-get update
apt-get install -y network-manager openssh-server tcpdump openssl python3 iw rfkill

log "Activando NetworkManager y SSH"
systemctl enable --now NetworkManager
systemctl enable --now ssh

# Evita que dhcpcd y NetworkManager intenten configurar las mismas interfaces.
if systemctl list-unit-files dhcpcd.service >/dev/null 2>&1; then
    systemctl disable --now dhcpcd.service 2>/dev/null || true
fi

check_interface "$WAN_IF"
check_interface "$LAN_IF"
check_interface "$WIFI_IF"

nmcli device set "$WAN_IF" managed yes
nmcli device set "$LAN_IF" managed yes
nmcli device set "$WIFI_IF" managed yes

rfkill unblock wifi
nmcli radio wifi on

if command -v raspi-config >/dev/null 2>&1; then
    raspi-config nonint do_wifi_country "$WIFI_COUNTRY" || true
fi
iw reg set "$WIFI_COUNTRY" 2>/dev/null || true

AP_SUPPORTED="$(nmcli -g WIFI-PROPERTIES.AP device show "$WIFI_IF" 2>/dev/null || true)"
if [[ "$AP_SUPPORTED" != "yes" ]]; then
    fail "$WIFI_IF no informa soporte para modo access point. Valor detectado: ${AP_SUPPORTED:-desconocido}"
fi

WIFI_MAC="$(cat "/sys/class/net/$WIFI_IF/address")"
IFS=':' read -r MAC1 MAC2 MAC3 MAC4 MAC5 MAC6 <<< "$WIFI_MAC"
[[ -n "${MAC6:-}" ]] || fail "No se pudo interpretar la MAC de $WIFI_IF: $WIFI_MAC"
SSID="pi_${MAC4^^}${MAC5^^}${MAC6^^}"

# Reutiliza la contraseña anterior si el archivo pertenece al mismo SSID.
WIFI_PASSWORD=""
if [[ -r "$CREDENTIALS_FILE" ]]; then
    SAVED_SSID="$(awk -F= '$1 == "SSID" {print substr($0, index($0, "=") + 1)}' "$CREDENTIALS_FILE" | head -n1)"
    SAVED_PASSWORD="$(awk -F= '$1 == "PASSWORD" {print substr($0, index($0, "=") + 1)}' "$CREDENTIALS_FILE" | head -n1)"
    if [[ "$SAVED_SSID" == "$SSID" && ${#SAVED_PASSWORD} -ge 8 ]]; then
        WIFI_PASSWORD="$SAVED_PASSWORD"
    fi
fi

if [[ -z "$WIFI_PASSWORD" ]]; then
    # 24 caracteres hexadecimales = 96 bits de entropía.
    WIFI_PASSWORD="$(openssl rand -hex 12)"
fi

umask 077
cat > "$CREDENTIALS_FILE" <<EOF_CREDS
SSID=$SSID
PASSWORD=$WIFI_PASSWORD
MANAGEMENT_IP=192.168.50.1
EOF_CREDS
chmod 600 "$CREDENTIALS_FILE"

log "Configurando $WAN_IF como WAN mediante DHCP"
disable_current_profile "$WAN_IF" "$WAN_PROFILE"
remove_profile "$WAN_PROFILE"

nmcli connection add \
    type ethernet \
    ifname "$WAN_IF" \
    con-name "$WAN_PROFILE" \
    connection.autoconnect yes \
    connection.autoconnect-priority 1000 \
    ipv4.method auto \
    ipv4.never-default no \
    ipv4.route-metric 100 \
    ipv6.method disabled >/dev/null

nmcli connection up "$WAN_PROFILE" ifname "$WAN_IF" || true
sleep 2
check_wan_overlap

log "Configurando $LAN_IF como LAN 10.0.0.1/24 con DHCP, DNS y NAT"
disable_current_profile "$LAN_IF" "$LAN_PROFILE"
remove_profile "$LAN_PROFILE"

nmcli connection add \
    type ethernet \
    ifname "$LAN_IF" \
    con-name "$LAN_PROFILE" \
    connection.autoconnect yes \
    connection.autoconnect-priority 900 \
    ipv4.method shared \
    ipv4.addresses "$LAN_ADDRESS" \
    ipv4.never-default yes \
    ipv6.method disabled >/dev/null

configure_optional_dhcp_range "$LAN_PROFILE" "$LAN_DHCP_RANGE"
nmcli connection up "$LAN_PROFILE" ifname "$LAN_IF"

log "Configurando $WIFI_IF como access point de management"
disable_current_profile "$WIFI_IF" "$AP_PROFILE"
remove_profile "$AP_PROFILE"

nmcli connection add \
    type wifi \
    ifname "$WIFI_IF" \
    con-name "$AP_PROFILE" \
    ssid "$SSID" >/dev/null

nmcli connection modify "$AP_PROFILE" \
    connection.autoconnect yes \
    connection.autoconnect-priority 1000 \
    802-11-wireless.mode ap \
    802-11-wireless.band bg \
    802-11-wireless.channel "$AP_CHANNEL" \
    802-11-wireless.hidden no \
    802-11-wireless.powersave 2 \
    802-11-wireless.cloned-mac-address permanent \
    802-11-wireless-security.key-mgmt wpa-psk \
    802-11-wireless-security.proto rsn \
    802-11-wireless-security.pairwise ccmp \
    802-11-wireless-security.psk "$WIFI_PASSWORD" \
    ipv4.method shared \
    ipv4.addresses "$MGMT_ADDRESS" \
    ipv4.never-default yes \
    ipv6.method disabled

configure_optional_dhcp_range "$AP_PROFILE" "$MGMT_DHCP_RANGE"
nmcli connection up "$AP_PROFILE" ifname "$WIFI_IF"

if [[ "$ENABLE_CAPTURE" == "yes" ]]; then
    log "Creando captura circular de $LAN_IF (${PCAP_FILE_COUNT} x ${PCAP_SIZE_MB} MB)"
    install -d -o root -g root -m 0700 "$PCAP_DIRECTORY"

    cat > /etc/systemd/system/eth1-capture.service <<EOF_SERVICE
[Unit]
Description=Captura circular de paquetes en $LAN_IF
After=NetworkManager.service network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/tcpdump -Z root -i $LAN_IF -nn -s 0 -U -C $PCAP_SIZE_MB -W $PCAP_FILE_COUNT -w $PCAP_DIRECTORY/eth1.pcap
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF_SERVICE

    systemctl daemon-reload
    systemctl enable --now eth1-capture.service
else
    systemctl disable --now eth1-capture.service 2>/dev/null || true
fi

log "Configuración final"
printf '\n'
ip -br -4 address
printf '\nRutas IPv4:\n'
ip -4 route

cat <<EOF_SUMMARY

============================================================
 CONFIGURACIÓN COMPLETADA
============================================================

Wi-Fi de management
  SSID:       $SSID
  Contraseña: $WIFI_PASSWORD
  Dirección:  192.168.50.1/24
  SSH:        ssh <usuario>@192.168.50.1

LAN de dispositivos
  Interfaz:   $LAN_IF
  Gateway:    10.0.0.1/24
  Salida:     NAT a través de $WAN_IF

WAN
  Interfaz:   $WAN_IF
  Método:     DHCP

Credenciales guardadas en:
  $CREDENTIALS_FILE
EOF_SUMMARY

if [[ "$ENABLE_CAPTURE" == "yes" ]]; then
    cat <<EOF_CAPTURE

Captura de tráfico
  Estado:     activada
  Interfaz:   $LAN_IF
  Directorio: $PCAP_DIRECTORY
  Límite:     $((PCAP_SIZE_MB * PCAP_FILE_COUNT)) MB aproximadamente

  Ver estado:
    systemctl status eth1-capture.service

  Detenerla:
    sudo systemctl disable --now eth1-capture.service
EOF_CAPTURE
fi

cat <<'EOF_END'

IMPORTANTE:
  La red que reciba eth0 no debe solaparse con 192.168.50.0/24
  ni con 10.0.0.0/24.
============================================================
EOF_END
