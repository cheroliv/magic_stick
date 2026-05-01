#!/usr/bin/env bash
set -euo pipefail

SMOKE_MARKER="SMOKE_TEST_COMPLETE:"
RESULT_FILE="/tmp/smoke_results"
PASS=0
FAIL=0
TOTAL=0

result() {
    local status="$1"
    local tool="$2"
    local detail="${3:-}"
    TOTAL=$((TOTAL + 1))
    if [[ "$status" == "PASS" ]]; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        echo "  [FAIL] ${tool}: ${detail}" >&2
    fi
    echo "${status}|${tool}"
}

smoke_test() {
    local tool="$1"
    shift
    if "$@" >/dev/null 2>&1; then
        result "PASS" "${tool}"
    else
        result "FAIL" "${tool}" "command failed"
    fi
}

smoke_version() {
    local tool="$1"
    local cmd="$2"
    if ${cmd} --version >/dev/null 2>&1 || ${cmd} -v >/dev/null 2>&1 || ${cmd} version >/dev/null 2>&1; then
        result "PASS" "${tool}"
    else
        result "FAIL" "${tool}" "version check failed"
    fi
}

{
    echo "=== Magic Stick Smoke Tests ==="
    echo ""

    smoke_test "docker"      docker info
    smoke_test "podman"      podman info
    smoke_test "ollama"      ollama --version
    smoke_test "nvm"         bash -c '. /opt/nvm/nvm.sh && nvm --version'
    smoke_test "pnpm"        bash -c 'export PNPM_HOME=/usr/local/pnpm && export PATH=$PNPM_HOME:$PATH && pnpm --version'
    smoke_version "python3"         "python3"
    smoke_version "uv"              "uv"
    smoke_test "java"        java -version
    smoke_test "nmap"        nmap --version
    smoke_test "iperf3"      iperf3 --version
    smoke_test "tshark"      tshark --version
    smoke_version "rg"              "rg"
    smoke_version "fd"              "fd"
    smoke_version "fzf"             "fzf"
    smoke_version "lazygit"         "lazygit"
    smoke_version "xh"              "xh"
    smoke_version "just"            "just"
    smoke_version "flatpak"         "flatpak"
    smoke_version "zsh"             "zsh"
    smoke_version "starship"        "starship"
    smoke_version "opencode"        "opencode"
    smoke_version "gh"              "gh"
    smoke_test "jetbrains-toolbox"  /usr/local/bin/jetbrains-toolbox --version

    # Docker run test (needs daemon)
    if systemctl start docker 2>/dev/null; then
        sleep 3
        if docker run --rm hello-world >/dev/null 2>&1; then
            result "PASS" "docker-hello-world"
        else
            result "FAIL" "docker-hello-world" "hello-world container failed"
        fi
    else
        result "FAIL" "docker-hello-world" "docker daemon failed"
    fi

    echo ""
    echo "${SMOKE_MARKER} PASS=${PASS} FAIL=${FAIL} TOTAL=${TOTAL}"
    echo "PASS=${PASS}" > "${RESULT_FILE}"
    echo "FAIL=${FAIL}" >> "${RESULT_FILE}"
    echo "TOTAL=${TOTAL}" >> "${RESULT_FILE}"
} 2>&1
