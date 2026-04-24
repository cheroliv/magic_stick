#!/usr/bin/env bash
set -euo pipefail

MAGIC_STICK_VERSION="0.1.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="${PROJECT_DIR}/build"
CONFIG_DIR="${PROJECT_DIR}/config/live-build"
ISO_NAME="magic_stick_${MAGIC_STICK_VERSION}.iso"
DOCKER_IMAGE="magic_stick:builder"

echo "=== Magic Stick Builder v${MAGIC_STICK_VERSION} ==="
echo "Project dir: ${PROJECT_DIR}"
echo "Build dir:    ${BUILD_DIR}"
echo "ISO name:     ${ISO_NAME}"
echo ""

usage() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  -c, --clean     Clean build artifacts (keep config)"
    echo "  -p, --purge     Purge everything (config + artifacts, start fresh)"
    echo "  -h, --help      Show this help message"
    echo "  -v, --verbose   Verbose output"
    echo ""
    echo "This script builds a Xubuntu-based live ISO using live-build inside Docker."
    echo "The resulting ISO can be flashed to a USB drive."
}

CLEAN=false
PURGE=false
VERBOSE=false

while [[ $# -gt 0 ]]; do
    case $1 in
        -c|--clean)
            CLEAN=true
            shift
            ;;
        -p|--purge)
            PURGE=true
            shift
            ;;
        -v|--verbose)
            VERBOSE=true
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            usage
            exit 1
            ;;
    esac
done

DOCKER_OPTS=()
if [[ "$VERBOSE" == true ]]; then
    DOCKER_OPTS+=(-e VERBOSE=1)
fi

docker_run() {
    docker run --rm \
        "${DOCKER_OPTS[@]}" \
        -v "${PROJECT_DIR}:/magic_stick" \
        "${DOCKER_IMAGE}" \
        bash -c "$*"
}

check_prerequisites() {
    echo "Checking prerequisites..."
    if ! command -v docker &>/dev/null; then
        echo "ERROR: docker is not installed"
        exit 1
    fi
    if ! docker info &>/dev/null; then
        echo "ERROR: docker daemon is not running"
        exit 1
    fi
    if ! docker image inspect "${DOCKER_IMAGE}" &>/dev/null; then
        echo "Docker image ${DOCKER_IMAGE} not found. Building..."
        docker build -t "${DOCKER_IMAGE}" "${PROJECT_DIR}"
    fi
    echo "Docker image ready."
}

setup_build_dir() {
    mkdir -p "${BUILD_DIR}"

    if [[ "$PURGE" == true ]]; then
        echo "Purging build directory..."
        docker_run "cd /magic_stick/build && lb clean --purge" 2>/dev/null || true
    elif [[ "$CLEAN" == true ]]; then
        echo "Cleaning build artifacts..."
        docker_run "cd /magic_stick/build && lb clean" 2>/dev/null || true
    fi

    if [[ ! -f "${BUILD_DIR}/config/common" ]]; then
        echo "Initializing live-build configuration..."
        docker_run "cd /magic_stick/build && lb config \
            --distribution noble \
            --architecture amd64 \
            --binary-images iso-hybrid \
            --mode ubuntu \
            --parent-distribution noble \
            --parent-mirror-bootstrap http://archive.ubuntu.com/ubuntu \
            --parent-mirror-binary http://archive.ubuntu.com/ubuntu \
            --mirror-bootstrap http://archive.ubuntu.com/ubuntu \
            --mirror-binary http://archive.ubuntu.com/ubuntu \
            --archive-areas 'main restricted universe multiverse' \
            --bootappend-live 'boot=live config username=magic hostname=magic_stick locales=fr_FR.UTF-8 keyboard-layouts=fr' \
            --iso-volume 'Magic Stick ${MAGIC_STICK_VERSION}' \
            --iso-publisher 'Magic Stick' \
            --iso-application 'Magic Stick Live System'"
    fi
}

apply_config() {
    echo "Applying Magic Stick configuration..."

    docker_run "cp -r /magic_stick/config/live-build/package-lists/* /magic_stick/build/config/package-lists/ 2>/dev/null || true"
    docker_run "chmod 644 /magic_stick/build/config/package-lists/*.list.chroot 2>/dev/null || true"

    if [[ -d "${CONFIG_DIR}/hooks" ]]; then
        docker_run "cp -r /magic_stick/config/live-build/hooks/* /magic_stick/build/config/hooks/ 2>/dev/null || true"
        docker_run "chmod 755 /magic_stick/build/config/hooks/*.chroot* 2>/dev/null || true"
    fi

    if [[ -d "${CONFIG_DIR}/includes.chroot" ]]; then
        docker_run "cp -r /magic_stick/config/live-build/includes.chroot/* /magic_stick/build/config/includes.chroot/ 2>/dev/null || true"
    fi

    if [[ -d "${CONFIG_DIR}/includes.binary" ]]; then
        docker_run "cp -r /magic_stick/config/live-build/includes.binary/* /magic_stick/build/config/includes.binary/ 2>/dev/null || true"
    fi
}

build_iso() {
    echo "Building ISO... (this will take 30-60 minutes)"
    docker_run "cd /magic_stick/build && lb build 2>&1 | tail -1; exit \${PIPESTATUS[0]}"

    local iso_path
    iso_path=$(find "${BUILD_DIR}" -maxdepth 1 -name 'live-image-*.iso' 2>/dev/null | head -1 || true)
    if [[ -n "${iso_path}" ]]; then
        local final_iso="${BUILD_DIR}/${ISO_NAME}"
        mv "${iso_path}" "$final_iso"
        echo ""
        echo "=== Build successful! ==="
        echo "ISO: ${final_iso}"
        echo "Size: $(du -h "$final_iso" | cut -f1)"
        echo ""
        echo "Flash to USB with:"
        echo "  sudo ${SCRIPT_DIR}/flash.sh /dev/sdX"
    else
        echo "ERROR: Build failed - no ISO file generated"
        echo "Check build/logs/ for details."
        exit 1
    fi
}

check_prerequisites
setup_build_dir
apply_config
build_iso

echo "Done."