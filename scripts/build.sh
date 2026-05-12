#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
MAGIC_STICK_VERSION="$(head -n 1 "${PROJECT_DIR}/VERSION" | tr -d '[:space:]')"
BUILD_DIR="${PROJECT_DIR}/build"
CONFIG_DIR="${PROJECT_DIR}/config/live-build"
ISO_NAME="magic-stick_${MAGIC_STICK_VERSION}.iso"
DOCKER_IMAGE="magic-stick:builder"

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
    echo "  -t, --test      Verify ISO and test boot after build"
    echo "  -h, --help      Show this help message"
    echo "  -v, --verbose   Verbose output"
    echo ""
    echo "All operations run inside a Docker container."
    echo "No sudo required. Nothing installed on the host."
}

CLEAN=false
PURGE=false
VERBOSE=false
TEST=false

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
        -t|--test)
            TEST=true
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

if [[ "$TEST" == true ]]; then
    DOCKER_OPTS+=(-e RUN_TEST=1)
fi

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

mkdir -p "${BUILD_DIR}"

echo "Launching build in Docker container..."
docker run --rm --privileged \
    "${DOCKER_OPTS[@]}" \
    -v "${PROJECT_DIR}:/magic-stick" \
    -e MAGIC_STICK_VERSION="${MAGIC_STICK_VERSION}" \
    -e CLEAN="${CLEAN}" \
    -e PURGE="${PURGE}" \
    "${DOCKER_IMAGE}" \
    /magic-stick/scripts/build-inner.sh

echo "Done."