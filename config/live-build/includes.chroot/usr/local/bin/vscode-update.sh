#!/usr/bin/env bash
set -euo pipefail

VSCODE_DIR="/opt/VSCode-linux-x64"
BACKUP_DIR="/opt/vscode-backup"
TEMP_DIR="/tmp/vscode-update"
YES_MODE=false

usage() {
    echo "Usage: vscode-update.sh [--yes]"
    echo "  --yes   Non-interactive, skip confirmation"
    exit 0
}

[[ "${1:-}" == "--help" || "${1:-}" == "-h" ]] && usage
[[ "${1:-}" == "--yes" ]] && YES_MODE=true

if [[ "${YES_MODE}" == false ]]; then
    echo "This will replace /opt/VSCode-linux-x64/ with the latest VS Code."
    echo "A backup will be saved to /opt/vscode-backup/"
    read -rp "Continue? [y/N] " yn
    [[ "${yn,,}" == "y" ]] || { echo "Aborted."; exit 0; }
fi

mkdir -p "$BACKUP_DIR" "$TEMP_DIR"

CURRENT_VERSION=$("${VSCODE_DIR}/bin/code" --version 2>/dev/null | head -1 || echo "unknown")
echo "Current version: ${CURRENT_VERSION}"

echo "Downloading latest VS Code..."
curl -fsSL "https://code.visualstudio.com/sha/download?build=stable&os=linux-x64" -o "${TEMP_DIR}/vscode.tar.gz"

echo "Extracting..."
mkdir -p "${TEMP_DIR}/extracted"
tar -xzf "${TEMP_DIR}/vscode.tar.gz" -C "${TEMP_DIR}/extracted"

NEW_VERSION=$("${TEMP_DIR}/extracted/VSCode-linux-x64/bin/code" --version 2>/dev/null | head -1 || echo "unknown")
echo "New version: ${NEW_VERSION}"

if [[ "$CURRENT_VERSION" == "$NEW_VERSION" ]]; then
    echo "Already up to date."
    rm -rf "$TEMP_DIR"
    exit 0
fi

echo "Backing up current installation..."
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
cp -a "$VSCODE_DIR" "${BACKUP_DIR}/VSCode-linux-x64-${TIMESTAMP}"

echo "Updating..."
rm -rf "$VSCODE_DIR"
mv "${TEMP_DIR}/extracted/VSCode-linux-x64" "$VSCODE_DIR"
rm -rf "$TEMP_DIR"

PRODUCT_JSON="${VSCODE_DIR}/resources/app/product.json"
if [[ -f "$PRODUCT_JSON" ]]; then
    echo "Removing checksums to prevent integrity warning..."
    python3 -c "
import json
with open('${PRODUCT_JSON}', 'r') as f:
    data = json.load(f)
data.pop('checksums', None)
with open('${PRODUCT_JSON}', 'w') as f:
    json.dump(data, f, indent=2)
" 2>/dev/null || echo "  WARNING: failed to patch product.json"
fi

ln -sf "${VSCODE_DIR}/bin/code" /usr/local/bin/code 2>/dev/null || true

echo "=== Update complete: ${CURRENT_VERSION} -> ${NEW_VERSION} ==="
