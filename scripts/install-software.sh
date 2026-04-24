#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
    echo "Usage: $0 <command>"
    echo ""
    echo "Commands:"
    echo "  docker     Install Docker CE"
    echo "  ollama     Install Ollama"
    echo "  sdkman     Install SDKMAN + JDK 21"
    echo "  all        Install everything above"
    echo ""
    echo "This script is intended to be run INSIDE the live system,"
    echo "not during the ISO build process."
    echo ""
    echo "For packages included in the ISO, see config/live-build/package-lists/"
}

USERNAME="${SUDO_USER:-$(whoami)}"
[ "$USERNAME" = "root" ] && USERNAME="magic"

install_docker() {
    echo "=== Installing Docker ==="

    if command -v docker &>/dev/null; then
        echo "  Docker already installed."
        return 0
    fi

    apt-get update
    apt-get install -y ca-certificates gnupg

    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
        -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc

    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
https://download.docker.com/linux/ubuntu \
$(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
        > /etc/apt/sources.list.d/docker.list

    apt-get update
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

    usermod -aG docker "$USERNAME" 2>/dev/null || true

    systemctl enable docker 2>/dev/null || true

    echo "  Docker installed."
}

install_ollama() {
    echo "=== Installing Ollama ==="

    if command -v ollama &>/dev/null; then
        echo "  Ollama already installed."
        return 0
    fi

    curl -fsSL https://ollama.com/install.sh | sh

    echo "  Ollama installed."
}

install_sdkman() {
    echo "=== Installing SDKMAN + JDK 21 ==="

    if command -v sdk &>/dev/null; then
        echo "  SDKMAN already installed."
        return 0
    fi

    local sdk_dir="/opt/sdkman"

    curl -s "https://get.sdkman.io" | bash
    export SDKMAN_DIR="$sdk_dir"
    source "${sdk_dir}/bin/sdkman-init.sh" 2>/dev/null || {
        echo "  WARNING: SDKMAN installation incomplete"
        return 1
    }

    if command -v sdk &>/dev/null; then
        sdk install java 21.0.2-tem
        echo "  SDKMAN + JDK 21 installed."
    else
        echo "  WARNING: SDKMAN installation incomplete"
    fi
}

if [[ $# -lt 1 ]]; then
    usage
    exit 1
fi

COMMAND="$1"

case "$COMMAND" in
    docker)
        install_docker
        ;;
    ollama)
        install_ollama
        ;;
    sdkman)
        install_sdkman
        ;;
    all)
        install_docker
        install_ollama
        install_sdkman
        ;;
    -h|--help|help)
        usage
        exit 0
        ;;
    *)
        echo "Unknown command: ${COMMAND}"
        usage
        exit 1
        ;;
esac