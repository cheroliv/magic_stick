#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="/magic_stick"
BUILD_DIR="${PROJECT_DIR}/build"
CONFIG_DIR="${PROJECT_DIR}/config/live-build"
ISO_NAME="magic_stick_${MAGIC_STICK_VERSION}.iso"

echo "=== Inner build (container) v${MAGIC_STICK_VERSION} ==="

if [[ "${PURGE}" == true ]]; then
    echo "Purging build directory..."
    cd "${BUILD_DIR}" && lb clean --purge 2>/dev/null || true
elif [[ "${CLEAN}" == true ]]; then
    echo "Cleaning build artifacts..."
    cd "${BUILD_DIR}" && lb clean 2>/dev/null || true
fi

if [[ ! -f "${BUILD_DIR}/config/common" ]]; then
    echo "Initializing live-build configuration..."
    cd "${BUILD_DIR}" && lb config \
        --distribution noble \
        --architecture amd64 \
        --binary-images iso-hybrid \
        --bootloader syslinux \
        --syslinux-theme live-build \
        --mode ubuntu \
        --initramfs casper \
        --parent-distribution noble \
        --parent-mirror-bootstrap http://archive.ubuntu.com/ubuntu \
        --parent-mirror-binary http://archive.ubuntu.com/ubuntu \
        --mirror-bootstrap http://archive.ubuntu.com/ubuntu \
        --mirror-binary http://archive.ubuntu.com/ubuntu \
        --archive-areas 'main restricted universe multiverse' \
        --bootappend-live 'boot=casper username=magic hostname=magic_stick locales=fr_FR.UTF-8 keyboard-layouts=fr quiet splash' \
        --iso-volume "Magic Stick ${MAGIC_STICK_VERSION}" \
        --iso-publisher 'Magic Stick' \
        --iso-application 'Magic Stick Live System'
fi

echo "Applying Magic Stick configuration..."
cp -r "${CONFIG_DIR}/package-lists/"* "${BUILD_DIR}/config/package-lists/" 2>/dev/null || true
chmod 644 "${BUILD_DIR}/config/package-lists/"*.list.chroot 2>/dev/null || true

if [[ -d "${CONFIG_DIR}/hooks" ]]; then
    cp -r "${CONFIG_DIR}/hooks/"* "${BUILD_DIR}/config/hooks/" 2>/dev/null || true
    chmod 755 "${BUILD_DIR}/config/hooks/"*.chroot* 2>/dev/null || true
fi

if [[ -d "${CONFIG_DIR}/includes.chroot" ]]; then
    cp -r "${CONFIG_DIR}/includes.chroot/"* "${BUILD_DIR}/config/includes.chroot/" 2>/dev/null || true
fi

if [[ -d "${CONFIG_DIR}/includes.binary" ]]; then
    cp -r "${CONFIG_DIR}/includes.binary/"* "${BUILD_DIR}/config/includes.binary/" 2>/dev/null || true
fi

echo "Building ISO... (this will take 30-60 minutes)"
cd "${BUILD_DIR}" && lb build 2>&1

ISO_PATH=$(find "${BUILD_DIR}" -maxdepth 1 -name 'live-image-*.iso' 2>/dev/null | head -1 || true)
if [[ -z "${ISO_PATH}" ]]; then
    echo "ERROR: Build failed - no ISO file generated"
    echo "Check build/logs/ for details."
    exit 1
fi

FINAL_ISO="${BUILD_DIR}/${ISO_NAME}"
mv "${ISO_PATH}" "${FINAL_ISO}"
echo ""
echo "=== Build successful! ==="
echo "ISO: ${FINAL_ISO}"
echo "Size: $(du -h "$FINAL_ISO" | cut -f1)"

if [[ "${RUN_TEST:-0}" == "1" ]]; then
    echo ""
    echo "=== Running post-build verification ==="
    /magic_stick/scripts/verify.sh "${FINAL_ISO}"
    echo ""
    echo "=== Running boot test ==="
    /magic_stick/scripts/test-boot.sh "${FINAL_ISO}"
fi

echo ""
echo "Next steps:"
echo "  Verify ISO:  scripts/verify.sh"
echo "  Test boot:   scripts/test-boot.sh"
echo "  Flash to USB: docker run --rm --device=/dev/sdX -v \$(pwd):/magic_stick magic_stick:builder /magic_stick/scripts/flash.sh /dev/sdX"