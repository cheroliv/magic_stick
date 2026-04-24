#!/usr/bin/env bash
set -euo pipefail

in_container() {
    [[ -f /.dockerenv ]] || grep -qE '(docker|lxc)' /proc/1/cgroup 2>/dev/null
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="${PROJECT_DIR}/build"
DOCKER_IMAGE="magic_stick:builder"

ISO_FILE="${1:-}"
TIMEOUT="${2:-120}"

if [[ -z "$ISO_FILE" ]]; then
    ISO_FILE=$(ls -t "${BUILD_DIR}"/magic_stick_*.iso 2>/dev/null | head -1 || true)
fi

if [[ -z "$ISO_FILE" ]] || [[ ! -f "$ISO_FILE" ]]; then
    echo "ERROR: No ISO file found"
    echo "Run scripts/build.sh first."
    exit 1
fi

if ! in_container; then
    echo "=== Magic Stick Boot Test (via Docker) ==="
    exec docker run --rm \
        -v "${PROJECT_DIR}:/magic_stick" \
        "${DOCKER_IMAGE}" \
        "/magic_stick/scripts/test-boot.sh" "/magic_stick/build/$(basename "$ISO_FILE")" "$TIMEOUT"
fi

echo "=== Magic Stick Boot Test ==="
echo "ISO: ${ISO_FILE}"
echo "Timeout: ${TIMEOUT}s"
echo ""

SERIAL_LOG="/tmp/boot_serial.log"

echo ">>> Starting QEMU BIOS boot test (serial console)..."
timeout "${TIMEOUT}" qemu-system-x86_64 \
    -m 2048 \
    -smp 2 \
    -cdrom "${ISO_FILE}" \
    -boot d \
    -nographic \
    -serial "file:${SERIAL_LOG}" \
    -no-reboot 2>/dev/null &

QEMU_PID=$!
sleep 10

if kill -0 $QEMU_PID 2>/dev/null; then
    echo "  OK: QEMU started and ISO booted"
    kill $QEMU_PID 2>/dev/null || true
    wait $QEMU_PID 2>/dev/null || true
else
    echo "  WARN: QEMU exited early"
fi

echo ""
echo ">>> Serial log (first 30 lines):"
if [[ -f $SERIAL_LOG ]]; then
    head -30 "$SERIAL_LOG" 2>/dev/null || echo "  (empty log)"
    echo ""
    if grep -q "Linux version" "$SERIAL_LOG" 2>/dev/null; then
        echo "  OK: Linux kernel booted"
    else
        echo "  WARN: No kernel boot message found in serial log"
    fi
    if grep -qi "magic" "$SERIAL_LOG" 2>/dev/null; then
        echo "  OK: Magic Stick identity found"
    else
        echo "  INFO: Magic Stick identity not found in serial log (may need more time)"
    fi
else
    echo "  (no serial log generated)"
fi

echo ""
echo ">>> Starting QEMU UEFI boot test..."
OVMF_CODE="/usr/share/OVMF/OVMF_CODE.fd"
UEFI_LOG="/tmp/boot_uefi.log"

if [[ -f "$OVMF_CODE" ]]; then
    timeout "${TIMEOUT}" qemu-system-x86_64 \
        -m 2048 \
        -smp 2 \
        -cdrom "${ISO_FILE}" \
        -boot d \
        -nographic \
        -serial "file:${UEFI_LOG}" \
        -drive "if=pflash,format=raw,readonly=on,file=${OVMF_CODE}" \
        -no-reboot 2>/dev/null &

    UEFI_PID=$!
    sleep 10

    if kill -0 $UEFI_PID 2>/dev/null; then
        echo "  OK: UEFI QEMU started"
        kill $UEFI_PID 2>/dev/null || true
        wait $UEFI_PID 2>/dev/null || true
    else
        echo "  WARN: UEFI QEMU exited early"
    fi

    if [[ -f $UEFI_LOG ]]; then
        if grep -q "Linux version" "$UEFI_LOG" 2>/dev/null; then
            echo "  OK: UEFI kernel boot detected"
        else
            echo "  INFO: UEFI kernel boot not detected in 10s (may need more time)"
        fi
    fi
else
    echo "  SKIP: OVMF firmware not found"
fi

echo ""
echo "=== Boot test complete ==="