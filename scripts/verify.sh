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

if [[ -z "$ISO_FILE" ]]; then
    ISO_FILE=$(ls -t "${BUILD_DIR}"/magic_stick_*.iso 2>/dev/null | head -1 || true)
fi

if [[ -z "$ISO_FILE" ]] || [[ ! -f "$ISO_FILE" ]]; then
    echo "ERROR: No ISO file found"
    echo "Run scripts/build.sh first."
    exit 1
fi

if ! in_container; then
    echo "=== Magic Stick ISO Verification (via Docker) ==="
    exec docker run --rm \
        -v "${PROJECT_DIR}:/magic_stick" \
        "${DOCKER_IMAGE}" \
        "/magic_stick/scripts/verify.sh" "/magic_stick/build/$(basename "$ISO_FILE")"
fi

echo "=== Magic Stick ISO Verification ==="
echo "File: ${ISO_FILE}"
echo ""

ISO_SIZE=$(stat -c%s "$ISO_FILE" 2>/dev/null)
ISO_SIZE_HUMAN=$(du -h "$ISO_FILE" | cut -f1)
MIN_SIZE=$((500 * 1024 * 1024))

echo "[1/5] Checking file exists..."
echo "  OK: File found"

echo "[2/5] Checking file size..."
if [[ "$ISO_SIZE" -gt "$MIN_SIZE" ]]; then
    echo "  OK: ${ISO_SIZE_HUMAN}"
else
    echo "  WARNING: ISO is smaller than expected (${ISO_SIZE_HUMAN})"
fi

echo "[3/5] Checking boot files (vmlinuz, initrd)..."
if isoinfo -i "$ISO_FILE" -l 2>/dev/null | grep -q "vmlinuz"; then
    echo "  OK: vmlinuz found"
else
    echo "  WARNING: vmlinuz not found in ISO"
fi
if isoinfo -i "$ISO_FILE" -l 2>/dev/null | grep -q "initrd"; then
    echo "  OK: initrd found"
else
    echo "  WARNING: initrd not found in ISO"
fi

echo "[4/5] Checking bootloader..."
if isoinfo -i "$ISO_FILE" -l 2>/dev/null | grep -q -E "(grub|syslinux|isolinux)"; then
    echo "  OK: Bootloader found"
else
    echo "  WARNING: No standard bootloader found"
fi

for _c32 in ldlinux.c32 libcom32.c32 libutil.c32 vesamenu.c32; do
    if isoinfo -i "$ISO_FILE" -l 2>/dev/null | grep -q "${_c32}"; then
        echo "  OK: ${_c32} found"
    else
        echo "  WARNING: ${_c32} NOT found — ISOLINUX boot may fail (GRUB2 is primary bootloader)"
    fi
done

echo "[5/7] Checking squashfs..."
if isoinfo -i "$ISO_FILE" -l 2>/dev/null | grep -q "filesystem.squashfs"; then
    echo "  OK: filesystem.squashfs found"
else
    echo "  WARNING: No squashfs filesystem found"
fi

echo "[6/7] Checking UEFI support..."
if isoinfo -i "$ISO_FILE" -l 2>/dev/null | grep -qi "efi"; then
    echo "  OK: EFI directory found in ISO"
else
    echo "  WARNING: No EFI directory found (UEFI boot not supported)"
fi

if isoinfo -i "$ISO_FILE" -l 2>/dev/null | grep -q "BOOTX64.EFI"; then
    echo "  OK: BOOTX64.EFI found (UEFI boot loader present)"
elif isoinfo -i "$ISO_FILE" -l 2>/dev/null | grep -q "grubx64.efi"; then
    echo "  OK: grubx64.efi found"
else
    echo "  WARNING: No EFI boot loader found"
fi

echo "[7/7] Checking GRUB config..."
if isoinfo -i "$ISO_FILE" -l 2>/dev/null | grep -q "grub.cfg"; then
    echo "  OK: grub.cfg found"
else
    echo "  WARNING: No grub.cfg found"
fi

echo ""
echo "=== Verification complete ==="
echo "ISO: ${ISO_FILE}"
echo "Size: ${ISO_SIZE_HUMAN}"