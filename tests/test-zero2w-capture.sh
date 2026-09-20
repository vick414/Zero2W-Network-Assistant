#!/usr/bin/env bash

set -Eeuo pipefail

PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
MOCK_DIR="$PROJECT_DIR/tests/mocks"
TEST_DIRECTORY="$(mktemp -d)"
CONFIG_FILE="$TEST_DIRECTORY/zero2w-capture.conf"
CAPTURE_DIRECTORY="$TEST_DIRECTORY/pcap"

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
CAPTURE_INTERFACE=eth1
CAPTURE_DIRECTORY=$CAPTURE_DIRECTORY
CAPTURE_FILE_PREFIX=eth1
CAPTURE_FILE_SIZE_MB=200
CAPTURE_MAX_FILES=10
CAPTURE_ROTATE_SECONDS=86400
CAPTURE_FILTER="tcp port 80"
CAPTURE_TCPDUMP_BIN=tcpdump
CAPTURE_SYSTEMCTL_BIN=systemctl
CAPTURE_IP_BIN=ip
EOF_CONFIG
}

run_capture_script() {
    local script="$1"
    shift
    env \
        PATH="$MOCK_DIR:$PATH" \
        ZERO2W_CAPTURE_TESTING=yes \
        ZERO2W_CAPTURE_COMMON="$PROJECT_DIR/capture/zero2w-capture-common" \
        ZERO2W_CAPTURE_PRUNE="$PROJECT_DIR/capture/zero2w-capture-prune" \
        ZERO2W_CAPTURE_CONFIG_FILE="$CONFIG_FILE" \
        "$PROJECT_DIR/capture/$script" "$@"
}

mkdir -p "$CAPTURE_DIRECTORY"
write_config

for script in \
    "$PROJECT_DIR/configure-pi-router.sh" \
    "$PROJECT_DIR/capture/zero2w-capture" \
    "$PROJECT_DIR/capture/zero2w-capture-common" \
    "$PROJECT_DIR/capture/zero2w-capture-prune" \
    "$PROJECT_DIR/capture/zero2w-capture-check" \
    "$PROJECT_DIR/capture/zero2w-capture-run"; do
    bash -n "$script" || fail "Shell syntax failed: $script"
done
pass "shell syntax"

MOCK_TCPDUMP_ARGS="$TEST_DIRECTORY/tcpdump-args" run_capture_script zero2w-capture-run >/dev/null
assert_contains "$TEST_DIRECTORY/tcpdump-args" "-C"
assert_contains "$TEST_DIRECTORY/tcpdump-args" "200"
assert_contains "$TEST_DIRECTORY/tcpdump-args" "-G"
assert_contains "$TEST_DIRECTORY/tcpdump-args" "86400"
assert_contains "$TEST_DIRECTORY/tcpdump-args" "$CAPTURE_DIRECTORY/eth1-%Y%m%d-%H%M%S.pcap"
assert_contains "$TEST_DIRECTORY/tcpdump-args" "-z"
assert_contains "$TEST_DIRECTORY/tcpdump-args" "$PROJECT_DIR/capture/zero2w-capture-prune"
assert_contains "$TEST_DIRECTORY/tcpdump-args" "tcp"
assert_contains "$TEST_DIRECTORY/tcpdump-args" "80"
assert_not_contains "$TEST_DIRECTORY/tcpdump-args" "-Z"
pass "runner configures size, time, filter, and post-rotation retention without root privilege dropping"

for index in $(seq 1 12); do
    file="$CAPTURE_DIRECTORY/eth1-20260919-1200${index}.pcap"
    printf 'capture %s\n' "$index" > "$file"
    touch -t "2026091912$(printf '%02d' "$index").00" "$file"
done
printf 'keep me\n' > "$CAPTURE_DIRECTORY/unrelated.pcap"

run_capture_script zero2w-capture-prune enforce
managed_count="$(find "$CAPTURE_DIRECTORY" -maxdepth 1 -type f -name 'eth1-*.pcap*' | wc -l | tr -d ' ')"
[[ "$managed_count" -eq 10 ]] || fail "Expected 10 managed files after enforce, found $managed_count"
[[ -f "$CAPTURE_DIRECTORY/unrelated.pcap" ]] || fail "Retention removed an unrelated file"
[[ ! -f "$CAPTURE_DIRECTORY/eth1-20260919-12001.pcap" ]] || fail "Retention did not remove the oldest file"
pass "global retention keeps the newest ten managed files only"

run_capture_script zero2w-capture-prune prepare
managed_count="$(find "$CAPTURE_DIRECTORY" -maxdepth 1 -type f -name 'eth1-*.pcap*' | wc -l | tr -d ' ')"
[[ "$managed_count" -eq 9 ]] || fail "Expected 9 managed files before startup, found $managed_count"
pass "startup reserves one retention slot for the new active file"

assert_contains "$PROJECT_DIR/capture/eth1-capture.service" "User=zero2w-capture"
assert_contains "$PROJECT_DIR/capture/eth1-capture.service" "AmbientCapabilities=CAP_NET_RAW CAP_NET_ADMIN"
assert_contains "$PROJECT_DIR/capture/eth1-capture.service" "ExecStartPre=+/usr/local/libexec/zero2w-capture-check"
assert_contains "$PROJECT_DIR/capture/eth1-capture.service" "ExecStopPost=+/usr/local/libexec/zero2w-capture-prune enforce"
pass "systemd unit uses a dedicated account and bounded capture capabilities"

assert_contains "$PROJECT_DIR/configure-pi-router.sh" 'CAPTURE_AUTO_START="${CAPTURE_AUTO_START:-yes}"'
assert_contains "$PROJECT_DIR/configure-pi-router.sh" 'CAPTURE_SERVICE_USER="zero2w-capture"'
assert_contains "$PROJECT_DIR/configure-pi-router.sh" '/usr/local/sbin/zero2w-capture enable'
assert_not_contains "$PROJECT_DIR/capture/zero2w-capture-run" '-Z'
pass "provisioning enables the managed non-root capture subsystem by default"

printf '1..%d\n' "$pass_count"
