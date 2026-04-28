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
    echo "=== Magic Stick Software Test (via Docker) ==="
    exec docker run --rm --privileged \
        -v "${PROJECT_DIR}:/magic_stick" \
        "${DOCKER_IMAGE}" \
        "/magic_stick/scripts/test-software.sh" "/magic_stick/build/$(basename "$ISO_FILE")"
fi

echo "=== Magic Stick Software Verification ==="
echo "ISO: ${ISO_FILE}"
echo ""

MOUNT_DIR=$(mktemp -d)
SQUASH_DIR=$(mktemp -d)

cleanup() {
    echo ">>> Cleaning up mounts..."
    umount "${SQUASH_DIR}" 2>/dev/null || true
    umount "${MOUNT_DIR}" 2>/dev/null || true
    rm -rf "${SQUASH_DIR}" "${MOUNT_DIR}"
}
trap cleanup EXIT

echo "[1/2] Mounting ISO..."
mount -o loop,ro "${ISO_FILE}" "${MOUNT_DIR}"
echo "  OK: ISO mounted at ${MOUNT_DIR}"

echo "[2/2] Extracting squashfs..."
SQUASHFS_FILE="${MOUNT_DIR}/live/filesystem.squashfs"
if [[ ! -f "${SQUASHFS_FILE}" ]]; then
    SQUASHFS_FILE="${MOUNT_DIR}/casper/filesystem.squashfs"
fi
unsquashfs -q -d "${SQUASH_DIR}" "${SQUASHFS_FILE}"
echo "  OK: squashfs extracted to ${SQUASH_DIR}"

echo "[3/3] Checking software installations..."
echo ""

TOTAL=0
PASS=0
FAIL=0

check_binary() {
    local name="$1"
    local paths=("${@:2}")
    TOTAL=$((TOTAL + 1))
    for path in "${paths[@]}"; do
        local fullpath="${SQUASH_DIR}${path}"
        if [[ -e "${fullpath}" ]]; then
            echo "  [PASS] ${name} found at ${path}"
            PASS=$((PASS + 1))
            return 0
        fi
        # Broken absolute symlinks in extracted squashfs: resolve against SQUASH_DIR
        if [[ -L "${fullpath}" ]]; then
            local target
            target=$(readlink "${fullpath}")
            if [[ "${target}" == /* ]]; then
                if [[ -e "${SQUASH_DIR}${target}" ]]; then
                    echo "  [PASS] ${name} found at ${path} (symlink -> ${target})"
                    PASS=$((PASS + 1))
                    return 0
                fi
            else
                local linkdir
                linkdir=$(dirname "${fullpath}")
                if [[ -e "${linkdir}/${target}" ]]; then
                    echo "  [PASS] ${name} found at ${path} (symlink -> ${target})"
                    PASS=$((PASS + 1))
                    return 0
                fi
            fi
        fi
    done
    echo "  [FAIL] ${name} NOT found (tried: ${paths[*]})"
    FAIL=$((FAIL + 1))
    return 1
}

check_file() {
    local name="$1"
    local path="$2"
    TOTAL=$((TOTAL + 1))
    if [[ -e "${SQUASH_DIR}${path}" ]]; then
        echo "  [PASS] ${name} found at ${path}"
        PASS=$((PASS + 1))
        return 0
    else
        echo "  [FAIL] ${name} NOT found at ${path}"
        FAIL=$((FAIL + 1))
        return 1
    fi
}

check_grep() {
    local name="$1"
    local file="$2"
    local pattern="$3"
    TOTAL=$((TOTAL + 1))
    if grep -q "${pattern}" "${SQUASH_DIR}${file}" 2>/dev/null; then
        echo "  [PASS] ${name} configured in ${file}"
        PASS=$((PASS + 1))
        return 0
    else
        echo "  [FAIL] ${name} NOT configured in ${file}"
        FAIL=$((FAIL + 1))
        return 1
    fi
}

echo ">>> Binaries:"
check_binary "docker" "/usr/bin/docker"
check_binary "podman" "/usr/bin/podman"
check_binary "ollama" "/usr/local/bin/ollama"
check_binary "nvm" "/opt/nvm/nvm.sh"
check_binary "pnpm" "/usr/local/bin/pnpm" "/opt/nvm/versions/node/v22.22.2/bin/pnpm"
check_binary "python3" "/usr/bin/python3" "/usr/local/bin/python3"
check_binary "uv" "/usr/local/bin/uv" "/usr/bin/uv"
check_binary "sdkman-init" "/opt/sdkman/bin/sdkman-init.sh"
check_binary "rg" "/usr/bin/rg" "/usr/local/bin/rg"
check_binary "fd" "/usr/bin/fdfind" "/usr/local/bin/fd"
check_binary "fzf" "/usr/bin/fzf" "/usr/local/bin/fzf"
check_binary "lazygit" "/usr/local/bin/lazygit"
check_binary "xh" "/usr/local/bin/xh"
check_binary "httpie" "/usr/bin/http"
check_binary "just" "/usr/local/bin/just"
check_binary "opencode" "/usr/local/bin/opencode"
check_binary "graphify" "/usr/local/bin/graphify"
check_binary "flatpak" "/usr/bin/flatpak"
check_binary "jetbrains-toolbox" "/usr/local/bin/jetbrains-toolbox" "/opt/jetbrains-toolbox/jetbrains-toolbox"
check_binary "zsh" "/usr/bin/zsh"
check_binary "starship" "/usr/bin/starship" "/usr/local/bin/starship"
check_binary "ffmpeg" "/usr/bin/ffmpeg"

echo ""
echo ">>> User configuration:"
check_file "oh-my-zsh" "/home/magic/.oh-my-zsh/oh-my-zsh.sh"
check_grep "starship-zsh" "/home/magic/.zshrc" "starship init zsh"

echo ""
echo "=== Software verification complete ==="
echo "Total: ${TOTAL}, Pass: ${PASS}, Fail: ${FAIL}"

if [[ ${FAIL} -gt 0 ]]; then
    echo "ERROR: ${FAIL} software checks failed"
    exit 1
else
    echo "OK: All software checks passed"
    exit 0
fi
