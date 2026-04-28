#!/usr/bin/env bash
# Launch Open-WebUI Docker container on port 3333 (instead of default 8080)
set -euo pipefail

CONTAINER_NAME="open-webui"
IMAGE="ghcr.io/open-webui/open-webui:main"
PORT="3333"
HOST="localhost"

echo "=== Magic Stick Open-WebUI Launcher ==="

# Check if Docker is running
if ! docker info > /dev/null 2>&1; then
    echo "ERROR: Docker daemon is not running!"
    echo "Start Docker: sudo systemctl start docker"
    exit 1
fi

# Check if container already running
if docker ps -q -f name=^"${CONTAINER_NAME}"$ > /dev/null 2>&1; then
    echo "Open-WebUI is already running!"
    echo "Open: http://${HOST}:${PORT}"
    exit 0
fi

# Remove old stopped container if exists
if docker ps -aq -f status=exited -f name=^"${CONTAINER_NAME}"$ > /dev/null 2>&1; then
    echo "Removing old container..."
    docker rm "${CONTAINER_NAME}" > /dev/null 2>&1 || true
fi

# Pull and run
echo "Starting Open-WebUI on http://${HOST}:${PORT} ..."
docker run -d \
    -p "${PORT}:8080" \
    -v open-webui:/app/backend/data \
    --name "${CONTAINER_NAME}" \
    --restart always \
    "${IMAGE}"

sleep 2

if docker ps -q -f name=^"${CONTAINER_NAME}"$ > /dev/null 2>&1; then
    echo "Open-WebUI is running at: http://${HOST}:${PORT}"
    echo "Configure Ollama API URL in Settings -> Admin Settings -> Connections"
    echo "Default Ollama URL when running locally: http://127.0.0.1:11434"
else
    echo "WARNING: Container started but check logs: docker logs ${CONTAINER_NAME}"
fi
