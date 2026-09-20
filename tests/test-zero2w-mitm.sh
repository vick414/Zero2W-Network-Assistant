#!/usr/bin/env bash

set -Eeuo pipefail

PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
MOCK_DIR="$PROJECT_DIR/tests/mocks"
TEST_DIRECTORY="$(mktemp -d)"
CONFIG_FILE="$TEST_DIRECTORY/zero2w-mitm.conf"
MODE_FILE="$TEST_DIRECTORY/mode"
IPTABLES_STATE="$TEST_DIRECTORY/iptables"
SYSTEMCTL_STATE="$TEST_DIRECTORY/systemctl-state"

trap 'rm -rf "$TEST_DIRECTORY"' EXIT

pass_count=0

pass() {
    pass_count=$((pass_count + 1))
    printf 'ok %d - %s\n' "$pass_count" "$1"
}

fail() {
    printf 'not ok - %s\n' "$1" >&2
    exit 1
}

assert_contains() {
    local file="$1"
    local pattern="$2"
    grep -Fq -- "$pattern" "$file" || fail "Expected '$pattern' in $file"
}

assert_not_contains() {
    local file="$1"
    local pattern="$2"
    if grep -Fq -- "$pattern" "$file"; then
        fail "Did not expect '$pattern' in $file"
    fi
}

write_config() {
    cat > "$CONFIG_FILE" <<EOF_CONFIG
MITM_LAN_IF=eth1
MITM_LISTEN_HOST=10.0.0.1
MITM_PORT=8080
MITM_DEFAULT_MODE=web
MITM_FLOW_DIR=$TEST_DIRECTORY/flows
MITM_STATE_DIR=$TEST_DIRECTORY
MITM_CONF_DIR=$TEST_DIRECTORY/confdir
MITM_MODE_FILE=$MODE_FILE
MITM_FIREWALL_STATE_FILE=$TEST_DIRECTORY/firewall-interface
MITM_BYPASS_CIDRS="10.0.0.1/32 192.168.50.0/24"
MITM_MITMDUMP_BIN=mitmdump
MITM_IPTABLES_BIN=iptables
MITM_SYSCTL_BIN=sysctl
MITM_SYSTEMCTL_BIN=systemctl
EOF_CONFIG
}

run_firewall() {
    env \
        PATH="$MOCK_DIR:$PATH" \
        MOCK_IPTABLES_STATE="$IPTABLES_STATE" \
        ZERO2W_MITM_TESTING=yes \
        ZERO2W_MITM_COMMON="$PROJECT_DIR/mitm/zero2w-mitm-common" \
        ZERO2W_MITM_CONFIG_FILE="$CONFIG_FILE" \
        "$PROJECT_DIR/mitm/zero2w-mitm-firewall" "$@"
}

mkdir -p "$TEST_DIRECTORY/flows" "$TEST_DIRECTORY/confdir" "$IPTABLES_STATE"
write_config
printf 'web\n' > "$MODE_FILE"

for script in \
    "$PROJECT_DIR/configure-pi-router.sh" \
    "$PROJECT_DIR/set-pi-router-wifi-password.sh" \
    "$PROJECT_DIR/mitm/zero2w-mitm" \
    "$PROJECT_DIR/mitm/zero2w-mitm-common" \
    "$PROJECT_DIR/mitm/zero2w-mitm-firewall" \
    "$PROJECT_DIR/mitm/zero2w-mitm-check" \
    "$PROJECT_DIR/mitm/zero2w-mitm-run"; do
    bash -n "$script" || fail "Shell syntax failed: $script"
done
pass "shell syntax"

# Preserve an unrelated rule through repeated apply/remove cycles.
PATH="$MOCK_DIR:$PATH" MOCK_IPTABLES_STATE="$IPTABLES_STATE" \
    iptables -w 5 -t nat -A PREROUTING -i wlan0 -j ACCEPT

run_firewall apply
run_firewall apply
[[ "$(grep -c -- 'zero2w-mitm' "$IPTABLES_STATE/prerouting")" -eq 1 ]] || fail "Repeated apply duplicated the PREROUTING jump"
assert_contains "$IPTABLES_STATE/rules-ZERO2W_MITM" "80\\,443"
assert_contains "$IPTABLES_STATE/rules-ZERO2W_MITM" "zero2w-mitm-web"
assert_not_contains "$IPTABLES_STATE/rules-ZERO2W_MITM" "zero2w-mitm-tcp"
pass "web mode is idempotent and redirects only ports 80 and 443"

run_firewall remove
run_firewall remove
assert_contains "$IPTABLES_STATE/prerouting" "wlan0"
assert_not_contains "$IPTABLES_STATE/prerouting" "zero2w-mitm"
[[ ! -f "$IPTABLES_STATE/chains/ZERO2W_MITM" ]] || fail "Project chain remained after disable"
pass "repeated disable removes only project rules"

printf 'tcp\n' > "$MODE_FILE"
run_firewall apply
assert_contains "$IPTABLES_STATE/rules-ZERO2W_MITM" "zero2w-mitm-tcp"
assert_not_contains "$IPTABLES_STATE/rules-ZERO2W_MITM" "--dports"
pass "tcp mode redirects all TCP without a port restriction"

# Cleanup still uses the original interface after a configuration change.
sed -i.bak 's/MITM_LAN_IF=eth1/MITM_LAN_IF=eth2/' "$CONFIG_FILE"
run_firewall remove
assert_not_contains "$IPTABLES_STATE/prerouting" "zero2w-mitm"
pass "disable removes the previous-interface jump after configuration changes"
mv "$CONFIG_FILE.bak" "$CONFIG_FILE"

printf 'invalid\n' > "$MODE_FILE"
if run_firewall apply >"$TEST_DIRECTORY/invalid.out" 2>&1; then
    fail "Invalid mode was accepted"
fi
assert_contains "$TEST_DIRECTORY/invalid.out" "invalid"
pass "invalid configured mode is rejected"

# A late apply failure must remove the jump and chain that were just created.
printf 'web\n' > "$MODE_FILE"
touch "$TEST_DIRECTORY/not-a-directory"
cp "$CONFIG_FILE" "$CONFIG_FILE.failure-backup"
sed -i.bak "s|MITM_FIREWALL_STATE_FILE=.*|MITM_FIREWALL_STATE_FILE=$TEST_DIRECTORY/not-a-directory/interface|" "$CONFIG_FILE"
if run_firewall apply >"$TEST_DIRECTORY/apply-failure.out" 2>&1; then
    fail "Firewall apply unexpectedly succeeded with an invalid state path"
fi
assert_not_contains "$IPTABLES_STATE/prerouting" "zero2w-mitm"
[[ ! -f "$IPTABLES_STATE/chains/ZERO2W_MITM" ]] || fail "Project chain remained after an apply failure"
mv "$CONFIG_FILE.failure-backup" "$CONFIG_FILE"
rm -f "$CONFIG_FILE.bak"
pass "partial firewall apply failure removes project rules"

printf 'web\n' > "$MODE_FILE"
env \
    PATH="$MOCK_DIR:$PATH" \
    MOCK_MITMDUMP_ARGS="$TEST_DIRECTORY/web-args" \
    ZERO2W_MITM_COMMON="$PROJECT_DIR/mitm/zero2w-mitm-common" \
    ZERO2W_MITM_CONFIG_FILE="$CONFIG_FILE" \
    "$PROJECT_DIR/mitm/zero2w-mitm-run" >/dev/null
assert_not_contains "$TEST_DIRECTORY/web-args" "tcp_hosts=.*"

printf 'tcp\n' > "$MODE_FILE"
env \
    PATH="$MOCK_DIR:$PATH" \
    MOCK_MITMDUMP_ARGS="$TEST_DIRECTORY/tcp-args" \
    ZERO2W_MITM_COMMON="$PROJECT_DIR/mitm/zero2w-mitm-common" \
    ZERO2W_MITM_CONFIG_FILE="$CONFIG_FILE" \
    "$PROJECT_DIR/mitm/zero2w-mitm-run" >/dev/null
assert_contains "$TEST_DIRECTORY/tcp-args" "tcp_hosts=.*"
assert_contains "$TEST_DIRECTORY/tcp-args" "rawtcp=true"
pass "mitmdump enables generic TCP handling only in tcp mode"

printf 'web\n' > "$MODE_FILE"
printf '\nMITM_MITMDUMP_BIN=missing-mitmdump\n' >> "$CONFIG_FILE"
if env \
    PATH="$MOCK_DIR:$PATH" \
    MOCK_IPTABLES_STATE="$IPTABLES_STATE" \
    MOCK_SYSTEMCTL_STATE="$SYSTEMCTL_STATE" \
    ZERO2W_MITM_TESTING=yes \
    ZERO2W_MITM_COMMON="$PROJECT_DIR/mitm/zero2w-mitm-common" \
    ZERO2W_MITM_FIREWALL="$PROJECT_DIR/mitm/zero2w-mitm-firewall" \
    ZERO2W_MITM_CONFIG_FILE="$CONFIG_FILE" \
    "$PROJECT_DIR/mitm/zero2w-mitm" enable web >"$TEST_DIRECTORY/missing.out" 2>&1; then
    fail "Missing mitmdump was accepted"
fi
assert_contains "$TEST_DIRECTORY/missing.out" "mitmdump is unavailable"
pass "missing mitmdump produces a useful error"

assert_contains "$PROJECT_DIR/mitm/zero2w-mitm.service" "ExecStopPost=+/usr/local/libexec/zero2w-mitm-firewall remove"
assert_contains "$PROJECT_DIR/mitm/zero2w-mitm.service" "ExecStartPost=+/usr/local/libexec/zero2w-mitm-firewall apply"
pass "systemd lifecycle installs after start and removes after failure or stop"

if grep -ERn -- 'iptables[^#]*-t[[:space:]]+nat[[:space:]]+-F([[:space:]]|$)' "$PROJECT_DIR/mitm"; then
    fail "Found a broad nat table flush"
fi
assert_contains "$PROJECT_DIR/mitm/zero2w-mitm-firewall" 'iptables_cmd -F "$CHAIN"'
pass "firewall cleanup is limited to ZERO2W_MITM"

assert_contains "$PROJECT_DIR/configure-pi-router.sh" 'ENABLE_MITM="${ENABLE_MITM:-no}"'
assert_contains "$PROJECT_DIR/configure-pi-router.sh" 'if [[ "$ENABLE_MITM" == "no" ]]'
pass "router provisioning keeps MITM disabled by default"

assert_contains "$PROJECT_DIR/configure-pi-router.sh" 'MITM_DOWNLOAD_INDEX="https://downloads.mitmproxy.org/list"'
assert_contains "$PROJECT_DIR/configure-pi-router.sh" "x86_64|amd64) printf 'x86_64"
assert_contains "$PROJECT_DIR/configure-pi-router.sh" "aarch64|arm64) printf 'aarch64"
assert_contains "$PROJECT_DIR/configure-pi-router.sh" 'mitmproxy-$version-linux-$architecture.tar.gz'
assert_not_contains "$PROJECT_DIR/configure-pi-router.sh" "pip install"
pass "automatic installer uses official architecture-specific standalone builds"

printf '1..%d\n' "$pass_count"
