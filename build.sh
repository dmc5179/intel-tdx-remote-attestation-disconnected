#!/bin/bash

podman build --squash -t quay.io/intel-tdx/pcs-base:latest -f PCS-Base-Containerfile .

podman build --squash -t quay.io/intel-tdx/pcs-client-tool:latest -f PCS-Client-Tool-Containerfile .

#podman build -t -f PCCS-Admin-Tool-Containerfile .

#podman build -t -f PCKCIDRT-Containerfile .
