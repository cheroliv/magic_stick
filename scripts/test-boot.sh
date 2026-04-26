#!/usr/bin/env bash
set -euo pipefail

in_container() {
    [[ -f /.dockerenv ]] || grep -qE '(docker|lxc)' /proc/1/cgroup 2>/dev/null
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="${PROJECT_DIR}/build"
DOCKER_IMAGE="magic_stick:builder"

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
fi

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

# Mode VNC needs port forwarding from host -> container
if ! in_container && [[ "$MODE" == "vnc" ]]; then
    echo "=== Magic Stick GUI Boot Test (via Docker + noVNC) ==="
    exec docker run --rm \
        -p 5900:5900 \
        -p 6080:6080 \
        -v "${PROJECT_DIR}:/magic_stick" \
        "${DOCKER_IMAGE}" \
        "/magic_stick/scripts/test-boot.sh" "--vnc" "/magic_stick/build/$(basename "$ISO_FILE")" "$TIMEOUT"
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
            echo "  Or reinstall Docker image with: docker build -t magic_stick:builder ."
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
