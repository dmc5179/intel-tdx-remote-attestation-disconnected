#!/bin/bash

set -euo pipefail

AUTHFILE=/home/danclark/quay-pull-secret.json
REGISTRY=quay.io/danclark/intel-tdx

echo "==> Building PCS Base image"
podman build --squash -t ${REGISTRY}/pcs-base:latest -f PCS-Base-Containerfile .
podman push --authfile=${AUTHFILE} ${REGISTRY}/pcs-base:latest

echo "==> Building PCS Client Tool image (runs on connected side)"
podman build --squash -t ${REGISTRY}/pcs-client-tool:latest -f PCS-Client-Tool-Containerfile .
podman push --authfile=${AUTHFILE} ${REGISTRY}/pcs-client-tool:latest

echo "==> Building PCCS Admin Tool image (runs in disconnected enclave)"
podman build --squash -t ${REGISTRY}/pccs-admin-tool:latest -f PCCS-Admin-Tool-Containerfile .
podman push --authfile=${AUTHFILE} ${REGISTRY}/pccs-admin-tool:latest

echo "==> Building PCCS image (runs in disconnected enclave)"
podman build --squash -t ${REGISTRY}/pccs:latest -f PCCS-Containerfile .
podman push --authfile=${AUTHFILE} ${REGISTRY}/pccs:latest
