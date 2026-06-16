#!/bin/bash
set -euo pipefail
trap 'echo "=== Failed at line $LINENO ===" >&2' ERR

SERVICE_NAME="${1:?Usage: ./deploy.sh <service_name>}"
VM="monorepo-server"
ZONE="us-west1-b"
REMOTE_DIR="/home/leo/monorepo"

echo "=== Building ${SERVICE_NAME} ==="
GOOS=linux GOARCH=amd64 go build -o "${SERVICE_NAME}" "./${SERVICE_NAME}"

echo "=== Uploading ${SERVICE_NAME}.tmp ==="
gcloud compute scp "./${SERVICE_NAME}/${SERVICE_NAME}" "leo@${VM}:${REMOTE_DIR}/${SERVICE_NAME}.tmp" --zone="${ZONE}"

echo "=== Replacing binary and restarting ==="
gcloud compute ssh "leo@${VM}" --zone="${ZONE}" --command="\
  mv ${REMOTE_DIR}/${SERVICE_NAME}.tmp ${REMOTE_DIR}/${SERVICE_NAME} && \
  chmod +x ${REMOTE_DIR}/${SERVICE_NAME} && \
  sudo systemctl restart ${SERVICE_NAME}"

echo "=== Done ==="
