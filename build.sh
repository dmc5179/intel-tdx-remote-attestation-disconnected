#!/bin/bash

AUTHFILE=/home/danclark/quay-pull-secret.json

podman build --squash -t quay.io/danclark/intel-tdx/pcs-base:latest -f PCS-Base-Containerfile .

podman push --authfile=${AUTHFILE} quay.io/danclark/intel-tdx/pcs-base:latest

podman build --squash -t quay.io/danclark/intel-tdx/pcs-client-tool:latest -f PCS-Client-Tool-Containerfile .

podman push --authfile=${AUTHFILE} quay.io/danclark/intel-tdx/pcs-client-tool:latest

podman build --squash -t quay.io/danclark/intel-tdx/pccs-admin-tool:latest  -f PCCS-Admin-Tool-Containerfile .

podman push --authfile=${AUTHFILE} quay.io/danclark/intel-tdx/pccs-admin-tool:latest

#podman build --squash -t quay.io/danclark/intel-tdx/pckcidrt:latest -f PCKCIDRT-Containerfile .

#podman push --authfile=${AUTHFILE} quay.io/danclark/intel-tdx/pckcidrt:latest
