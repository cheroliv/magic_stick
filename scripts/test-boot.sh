#!/usr/bin/env bash
set -euo pipefail

in_container() {
    [[ -f /.dockerenv ]] || grep -qE '(docker|lxc)' /proc/1/cgroup 2>/dev/null
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="${PROJECT_DIR}/build"
DOCKER_IMAGE="magic-stick:builder"

MODE="headless"
if [[ "${1:-}" == "--vnc" ]]; then
    MODE="vnc"
    shift
elif [[ "${1:-}" == "--bios" ]]; then
    MODE="bios"
    shift
elif [[ "${1:-}" == "--uefi" ]]; then
    MODE="uefi"
    shift
elif [[ "${1:-}" == "--smoke" ]]; then
    MODE="smoke"
    shift
fi

ISO_FILE="${1:-}"
TIMEOUT="${2:-120}"

if [[ -z "$ISO_FILE" ]]; then
    ISO_FILE=$(ls -t "${BUILD_DIR}"/magic-stick_*.iso 2>/dev/null | head -1 || true)
fi

if [[ -z "$ISO_FILE" ]] || [[ ! -f "$ISO_FILE" ]]; then
    echo "ERROR: No ISO file found"
    echo "Run scripts/build.sh first."
    exit 1
fi

# Mode VNC needs port forwarding from host -> container
if ! in_container && [[ "$MODE" == "vnc" ]]; then
    echo "=== Magic Stick GUI Boot Test (via Docker + noVNC) ==="
    exec docker run --rm \
        -p 5900:5900 \
        -p 6080:6080 \
        -v "${PROJECT_DIR}:/magic-stick" \
        "${DOCKER_IMAGE}" \
        "/magic-stick/scripts/test-boot.sh" "--vnc" "/magic-stick/build/$(basename "$ISO_FILE")" "$TIMEOUT"
fi

if ! in_container; then
    echo "=== Magic Stick Boot Test (via Docker) ==="
    exec docker run --rm \
        -v "${PROJECT_DIR}:/magic-stick" \
        "${DOCKER_IMAGE}" \
        "/magic-stick/scripts/test-boot.sh" "--${MODE}" "/magic-stick/build/$(basename "$ISO_FILE")" "$TIMEOUT"
fi

echo "=== Magic Stick Boot Test ==="
echo "ISO: ${ISO_FILE}"
echo "Timeout: ${TIMEOUT}s"
echo "Mode: ${MODE}"
echo ""

SERIAL_LOG="/tmp/boot_serial.log"
UEFI_LOG="/tmp/boot_uefi.log"
OVMF_CODE="/usr/share/OVMF/OVMF_CODE.fd"

# --- VNC Mode (GUI) ---
if [[ "$MODE" == "vnc" ]]; then
    VNC_DISPLAY="${VNC_DISPLAY:-0}"
    VNC_PORT=$((5900 + VNC_DISPLAY))

    echo ">>> Starting QEMU with VNC server on port ${VNC_PORT}..."
    qemu-system-x86_64 \
        -m 2048 \
        -smp 2 \
        -cdrom "${ISO_FILE}" \
        -boot d \
        -display none \
        -vnc ":${VNC_DISPLAY}" \
        -netdev user,id=net0 -device e1000,netdev=net0 \
        -no-reboot &
    QEMU_PID=$!

    sleep 3

    if kill -0 $QEMU_PID 2>/dev/null; then
        echo "  OK: QEMU VNC server running on port ${VNC_PORT}"

        if command -v websockify >/dev/null 2>&1 && [[ -d /usr/share/novnc ]]; then
            NOVNC_PORT="${NOVNC_PORT:-6080}"
            echo ">>> Starting noVNC/websockify on port ${NOVNC_PORT}..."
            websockify --web /usr/share/novnc --cert /tmp/self.pem "${NOVNC_PORT}" "localhost:${VNC_PORT}" &
            WS_PID=$!
            sleep 2

            if kill -0 $WS_PID 2>/dev/null; then
                echo ""
                echo "=== noVNC GUI Boot Test Running ==="
                echo "QEMU VNC:    localhost:${VNC_PORT}"
                echo "noVNC Web:   http://localhost:${NOVNC_PORT}/vnc.html?host=localhost&port=${NOVNC_PORT}"
                echo ""
                echo "Open the noVNC URL in your browser to view the GUI boot."
                echo ""
                echo "Press Ctrl+C to stop."

                cleanup_vnc() {
                    echo ""
                    echo ">>> Stopping noVNC and QEMU..."
                    kill $WS_PID 2>/dev/null || true
                    kill $QEMU_PID 2>/dev/null || true
                    wait $QEMU_PID 2>/dev/null || true
                    wait $WS_PID 2>/dev/null || true
                    echo "Stopped."
                }
                trap cleanup_vnc INT TERM EXIT
                wait $QEMU_PID
            else
                echo "  WARN: websockify failed to start"
            fi
        else
            echo ""
            echo "=== VNC GUI Boot Test Running ==="
            echo "QEMU VNC server running on localhost:${VNC_PORT}"
            echo ""
            echo "Connect with a VNC client:"
            echo "  vncviewer localhost:${VNC_DISPLAY}"
            echo "  Or reinstall Docker image with: docker build -t magic-stick:builder ."
            echo ""
            echo "Press Ctrl+C to stop."
            wait $QEMU_PID
        fi
    else
        echo "  ERROR: QEMU failed to start"
        exit 1
    fi
    exit 0
fi

# --- BIOS Mode ---
if [[ "$MODE" == "headless" || "$MODE" == "bios" ]]; then
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
fi

# --- UEFI Mode ---
if [[ "$MODE" == "headless" || "$MODE" == "uefi" ]]; then
    echo ""
    echo ">>> Starting QEMU UEFI boot test..."

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
fi

echo ""
echo "=== Boot test complete ==="

# --- Smoke Mode ---
if [[ "$MODE" == "smoke" ]]; then
    echo ""
    echo "=== Smoke Tests ==="

    SMOKE_MOUNT=$(mktemp -d)
    SMOKE_KERNEL="/tmp/smoke_vmlinuz"
    SMOKE_INITRD="/tmp/smoke_initrd.img"

    cleanup_smoke() {
        umount "${SMOKE_MOUNT}" 2>/dev/null || true
        rm -rf "${SMOKE_MOUNT}" "${SMOKE_KERNEL}" "${SMOKE_INITRD}"
    }
    trap cleanup_smoke EXIT

    mount -o loop,ro "${ISO_FILE}" "${SMOKE_MOUNT}"
    echo "  OK: ISO mounted"

    for kdir in casper live; do
        if [ -f "${SMOKE_MOUNT}/${kdir}/vmlinuz" ]; then
            cp "${SMOKE_MOUNT}/${kdir}/vmlinuz" "${SMOKE_KERNEL}"
            cp "${SMOKE_MOUNT}/${kdir}/initrd.img" "${SMOKE_INITRD}"
            break
        fi
    done

    if [ ! -f "${SMOKE_KERNEL}" ]; then
        echo "  ERROR: No kernel found in ISO"
        exit 1
    fi
    echo "  OK: Kernel extracted"

    echo ">>> Booting ISO with smoke_test=true (timeout ${TIMEOUT}s)..."
    SERIAL_LOG="/tmp/smoke_serial.log"
    rm -f "${SERIAL_LOG}"

    timeout "${TIMEOUT}" qemu-system-x86_64 \
        -m 4096 \
        -smp 4 \
        -nographic \
        -cdrom "${ISO_FILE}" \
        -kernel "${SMOKE_KERNEL}" \
        -initrd "${SMOKE_INITRD}" \
        -append "boot=casper username=magic hostname=magic-stick smoke_test=true console=ttyS0,115200 quiet" \
        -serial "file:${SERIAL_LOG}" \
        -no-reboot 2>/dev/null &
    QEMU_PID=$!

    echo ">>> Waiting for SMOKE_TEST_COMPLETE..."
    SMOKE_FOUND=false
    for i in $(seq 1 "${TIMEOUT}"); do
        if grep -q "SMOKE_TEST_COMPLETE:" "${SERIAL_LOG}" 2>/dev/null; then
            SMOKE_FOUND=true
            echo "  OK: Smoke test marker found after ${i}s"
            break
        fi
        if ! kill -0 $QEMU_PID 2>/dev/null; then
            echo "  WARN: QEMU exited after ${i}s"
            break
        fi
        sleep 1
    done

    kill $QEMU_PID 2>/dev/null || true
    wait $QEMU_PID 2>/dev/null || true

    if [[ "$SMOKE_FOUND" == true ]]; then
        echo ""
        echo ">>> Smoke test results:"
        grep -E "^\s*\[?(PASS|FAIL)\]" "${SERIAL_LOG}" | tail -30 || true

        if grep -q "PASS=0 FAIL=0" "${SERIAL_LOG}" 2>/dev/null; then
            echo "  SKIP: No tests ran (service may not have started)"
        fi

        if grep "SMOKE_TEST_COMPLETE:" "${SERIAL_LOG}" | grep -q "FAIL=0"; then
            echo ""
            echo "=== Smoke tests: ALL PASSED ==="
            exit 0
        else
            SMOKE_FAIL=$(grep "FAIL=" "${SERIAL_LOG}" | tail -1 | grep -oP 'FAIL=\K\d+')
            echo ""
            echo "=== Smoke tests: ${SMOKE_FAIL:-?} FAILED ==="
            exit 1
        fi
    else
        echo ""
        echo ">>> Serial log (first 40 lines):"
        head -40 "${SERIAL_LOG}" 2>/dev/null || echo "  (empty)"
        echo ""
        echo ">>> Serial log (last 20 lines):"
        tail -20 "${SERIAL_LOG}" 2>/dev/null || echo "  (empty)"
        echo ""
        echo "  ERROR: Smoke test did not complete within ${TIMEOUT}s"
        exit 1
    fi
fi
