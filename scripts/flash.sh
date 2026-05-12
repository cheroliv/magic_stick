#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="${PROJECT_DIR}/build"

usage() {
    echo "Usage: $0 <device>"
    echo ""
    echo "Flash the Magic Stick ISO to a USB drive."
    echo ""
    echo "Arguments:"
    echo "  device    Target device (e.g., /dev/sdX or /dev/disk/by-id/...)"
    echo ""
    echo "WARNING: This will ERASE ALL DATA on the target device!"
    echo ""
    echo "Run inside Docker (no sudo needed on host):"
    echo "  docker run --rm --device=/dev/sdX -v \$(pwd):/magic-stick magic-stick:builder scripts/flash.sh /dev/sdX"
    echo ""
    echo "First, identify your USB drive with:"
    echo "  lsblk"
}

if [[ $# -lt 1 ]]; then
    usage
    exit 1
fi

DEVICE="$1"

if [[ "$(id -u)" -ne 0 ]]; then
    echo "ERROR: This script must be run as root (use sudo)"
    exit 1
fi

if [[ ! -b "$DEVICE" ]]; then
    echo "ERROR: ${DEVICE} is not a block device"
    exit 1
fi

ISO_FILE=$(ls -t "${BUILD_DIR}"/magic-stick_*.iso 2>/dev/null | head -1)

if [[ -z "$ISO_FILE" ]]; then
    echo "ERROR: No ISO file found in ${BUILD_DIR}/"
    echo "Run scripts/build.sh first."
    exit 1
fi

ISO_SIZE=$(stat -c%s "$ISO_FILE" 2>/dev/null || stat -f%z "$ISO_FILE" 2>/dev/null)
DEVICE_SIZE=$(blockdev --getsize64 "$DEVICE" 2>/dev/null || echo 0)
MIN_DEVICE_SIZE=$((8 * 1024 * 1024 * 1024))

if [[ "$DEVICE_SIZE" -lt "$MIN_DEVICE_SIZE" ]]; then
    echo "ERROR: Device ${DEVICE} is too small ($(numfmt --to=iec "$DEVICE_SIZE"))"
    echo "Minimum required: 8 GB"
    exit 1
fi

if [[ "$ISO_SIZE" -ge "$DEVICE_SIZE" ]]; then
    echo "ERROR: ISO ($(numfmt --to=iec "$ISO_SIZE")) is larger than device ($(numfmt --to=iec "$DEVICE_SIZE"))"
    exit 1
fi

echo "=== Magic Stick Flasher ==="
echo ""
echo "ISO:    ${ISO_FILE} ($(numfmt --to=iec "$ISO_SIZE"))"
echo "Device: ${DEVICE} ($(numfmt --to=iec "$DEVICE_SIZE"))"
echo ""
echo "WARNING: This will ERASE ALL DATA on ${DEVICE}!"
echo ""
read -p "Type 'YES' to continue: " confirm

if [[ "$confirm" != "YES" ]]; then
    echo "Aborted."
    exit 0
fi

echo ""
echo "Unmounting partitions on ${DEVICE}..."
lsblk -n -o NAME,MOUNTPOINT "$DEVICE" 2>/dev/null | while read -r name mp; do
    if [[ -n "$mp" ]]; then
        echo "  Unmounting ${mp}..."
        umount "/dev/${name}" 2>/dev/null || true
    fi
done
umount "${DEVICE}"* 2>/dev/null || true

echo ""
echo "Flashing ISO to ${DEVICE}..."
echo "  (This may take a few minutes)"
dd if="$ISO_FILE" of="$DEVICE" bs=4M status=progress conv=fsync

echo ""
echo "Syncing..."
sync

echo ""
echo "=== Flash complete! ==="
echo "You can now boot from the USB drive."
echo ""
echo "Next steps for A/B partitioning:"
echo "  sudo ${SCRIPT_DIR}/update-system.sh --setup-ab ${DEVICE}"