#!/usr/bin/env bash
set -euo pipefail

in_container() {
    [[ -f /.dockerenv ]] || grep -qE '(docker|lxc)' /proc/1/cgroup 2>/dev/null
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="${PROJECT_DIR}/build"
DOCKER_IMAGE="magic-stick:builder"

ISO_FILE="${1:-}"

if [[ -z "$ISO_FILE" ]]; then
    ISO_FILE=$(ls -t "${BUILD_DIR}"/magic-stick_*.iso 2>/dev/null | head -1 || true)
fi

if [[ -z "$ISO_FILE" ]] || [[ ! -f "$ISO_FILE" ]]; then
    echo "ERROR: No ISO file found"
    echo "Run scripts/build.sh first."
    exit 1
fi

if ! in_container; then
    echo "=== Magic Stick Software Test (via Docker) ==="
    exec docker run --rm --privileged \
        -v "${PROJECT_DIR}:/magic-stick" \
        "${DOCKER_IMAGE}" \
        "/magic-stick/scripts/test-software.sh" "/magic-stick/build/$(basename "$ISO_FILE")"
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
check_binary "python3.14" "/usr/bin/python3.14" "/usr/local/bin/python3.14"
check_binary "python3" "/usr/bin/python3" "/usr/local/bin/python3"
check_binary "uv" "/usr/local/bin/uv" "/usr/bin/uv"
check_binary "sdkman-init" "/opt/sdkman/bin/sdkman-init.sh"
check_binary "java" "/opt/sdkman/candidates/java/current/bin/java"
check_binary "rg" "/usr/bin/rg" "/usr/local/bin/rg"
check_binary "fd" "/usr/bin/fdfind" "/usr/local/bin/fd"
check_binary "fzf" "/usr/bin/fzf" "/usr/local/bin/fzf"
check_binary "lazygit" "/usr/local/bin/lazygit"
check_binary "xh" "/usr/local/bin/xh"
check_binary "just" "/usr/local/bin/just"
check_binary "opencode" "/usr/local/bin/opencode"
check_binary "graphify" "/usr/local/bin/graphify"
check_binary "flatpak" "/usr/bin/flatpak"
check_binary "jetbrains-toolbox" "/usr/local/bin/jetbrains-toolbox" "/opt/jetbrains-toolbox/bin/jetbrains-toolbox"
check_binary "zsh" "/usr/bin/zsh"
check_binary "starship" "/usr/bin/starship" "/usr/local/bin/starship"
check_binary "ffmpeg" "/usr/bin/ffmpeg"
check_binary "nmap" "/usr/bin/nmap"
check_binary "iperf3" "/usr/bin/iperf3"
check_binary "wireshark" "/usr/bin/wireshark" "/usr/bin/tshark"
check_binary "code" "/usr/local/bin/code"
check_file "vscode-update" "/usr/local/bin/vscode-update.sh"
check_binary "gh" "/usr/local/bin/gh"

echo ""
echo ">>> User configuration:"
check_file "oh-my-zsh" "/home/magic/.oh-my-zsh/oh-my-zsh.sh"
check_grep "starship-zsh" "/home/magic/.zshrc" "starship init zsh"

echo ""
echo ">>> Reproducibility: pinned versions match versions.sh"

VERSIONS_SRC="${PROJECT_DIR}/scripts/lib/versions.sh"
REPRO_TOTAL=0
REPRO_PASS=0
REPRO_FAIL=0

repro_check() {
    local label="$1"
    local expected="$2"
    shift 2
    REPRO_TOTAL=$((REPRO_TOTAL + 1))
    if [[ "${expected}" == "latest" ]]; then
        echo "  [SKIP] ${label}: versions.sh says 'latest' (not pined yet)"
        return 0
    fi
    for arg in "$@"; do
        IFS='|' read -ra METHOD_PATH <<< "$arg"
        local method="${METHOD_PATH[0]}"
        local path="${METHOD_PATH[1]}"
        for method_attempt in ${method//,/ }; do
            case "${method_attempt}" in
                binary-grep)
                    if [ -f "${SQUASH_DIR}${path}" ]; then
                        local expected_nov="${expected#v}"
                        if strings "${SQUASH_DIR}${path}" 2>/dev/null | grep -qF "${expected}"; then
                            echo "  [PASS] ${label}: version ${expected} found in ${path}"
                            REPRO_PASS=$((REPRO_PASS + 1))
                            return 0
                        elif [[ "${expected_nov}" != "${expected}" ]] && strings "${SQUASH_DIR}${path}" 2>/dev/null | grep -qF "${expected_nov}"; then
                            echo "  [PASS] ${label}: version ${expected_nov} found in ${path}"
                            REPRO_PASS=$((REPRO_PASS + 1))
                            return 0
                        fi
                    fi
                    ;;
                dir-name)
                    if ls -d "${SQUASH_DIR}${path}"/*"${expected}"* >/dev/null 2>&1; then
                        echo "  [PASS] ${label}: version ${expected} found in ${path}"
                        REPRO_PASS=$((REPRO_PASS + 1))
                        return 0
                    fi
                    ;;
                symlink)
                    local target
                    target=$(readlink "${SQUASH_DIR}${path}" 2>/dev/null || echo "")
                    if [[ "${target}" == *"${expected}"* ]]; then
                        echo "  [PASS] ${label}: version ${expected} via symlink ${path}"
                        REPRO_PASS=$((REPRO_PASS + 1))
                        return 0
                    fi
                    ;;
            esac
        done
    done
    echo "  [FAIL] ${label}: version ${expected} NOT found in squashfs"
    REPRO_FAIL=$((REPRO_FAIL + 1))
    return 1
}

if [ -f "${VERSIONS_SRC}" ]; then
    . "${VERSIONS_SRC}"
    repro_check "ripgrep"    "${RIPGREP_VERSION}"    "binary-grep|/usr/local/bin/rg" "binary-grep|/usr/bin/rg"
    repro_check "fd"         "${FD_VERSION}"         "binary-grep|/usr/local/bin/fd"
    repro_check "fzf"        "${FZF_VERSION}"        "binary-grep|/usr/local/bin/fzf" "binary-grep|/usr/bin/fzf"
    repro_check "lazygit"    "${LAZYGIT_VERSION}"    "binary-grep|/usr/local/bin/lazygit"
    repro_check "just"       "${JUST_VERSION}"       "binary-grep|/usr/local/bin/just"
    repro_check "xh"         "${XH_VERSION}"         "binary-grep|/usr/local/bin/xh"
    repro_check "opencode"   "${OPENCODE_VERSION}"   "binary-grep|/usr/local/bin/opencode"
    repro_check "uv"         "${UV_VERSION}"         "binary-grep|/usr/local/bin/uv"
    repro_check "gh"         "${GHCLI_VERSION}"      "binary-grep|/usr/local/bin/gh"
    repro_check "nvm"        "${NVM_VERSION}"        "dir-name|/opt/nvm" "binary-grep|/opt/nvm/nvm.sh"
    repro_check "jetbrains"  "${JETBRAINS_TOOLBOX_VERSION}" "binary-grep|/opt/jetbrains-toolbox/bin/jetbrains-toolbox"
    repro_check "starship"   "${STARSHIP_VERSION}"   "binary-grep|/usr/local/bin/starship" "binary-grep|/usr/bin/starship"
    repro_check "sdkman"     "${SDKMAN_VERSION}"     "binary-grep|/opt/sdkman/bin/sdkman-init.sh"
    repro_check "vscode"     "${VSCODE_VERSION}"     "binary-grep|/opt/VSCode-linux-x64/bin/code"
else
    echo "  [SKIP] versions.sh not found at ${VERSIONS_SRC}"
fi

echo ""
echo "Reproducibility: Total ${REPRO_TOTAL}, Pass ${REPRO_PASS}, Fail ${REPRO_FAIL}"

if [ ${REPRO_FAIL} -gt 0 ]; then
    TOTAL=$((TOTAL + REPRO_TOTAL))
    FAIL=$((FAIL + REPRO_FAIL))
fi

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
