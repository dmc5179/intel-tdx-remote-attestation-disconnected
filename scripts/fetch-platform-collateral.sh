#!/bin/bash
set -euo pipefail

# Automate the Intel TDX platform collateral workflow:
#   1. Collect CSV files from TDX hosts into a platform_list.json
#   2. Fetch collateral from Intel PCS using the API key
#   3. Optionally insert into a running PCCS instance
#
# This script runs on the internet-connected side. For disconnected
# environments, use --fetch-only and transfer platform_collaterals.json
# via sneakernet.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

PCS_CLIENT_IMAGE="${PCS_CLIENT_IMAGE:-quay.io/danclark/intel-tdx/pcs-client-tool:latest}"
ADMIN_TOOL_IMAGE="${ADMIN_TOOL_IMAGE:-quay.io/danclark/intel-tdx/pccs-admin-tool:latest}"
WORK_DIR="${WORK_DIR:-$REPO_ROOT/collateral-output}"

usage() {
    cat <<EOF
Usage: $(basename "$0") <command> [OPTIONS]

Automate Intel TDX platform collateral collection from Intel PCS.

Commands:
  collect <csv-dir>            Merge host CSV files into platform_list.json
  fetch                        Fetch collateral from Intel PCS (requires API key)
  insert <pccs-url>            Insert collateral into a running PCCS instance
  full <csv-dir> <pccs-url>    Run all three steps end-to-end

Options:
  --api-key KEY             Intel PCS API subscription key (or set INTEL_PCS_API_KEY)
  --admin-token TOKEN       PCCS admin token for insert (or set PCCS_ADMIN_TOKEN)
  --work-dir DIR            Working directory for output files (default: collateral-output/)
  --pcs-client-image IMG    PCS Client Tool image (default: quay.io/danclark/intel-tdx/pcs-client-tool:latest)
  --admin-tool-image IMG    PCCS Admin Tool image (default: quay.io/danclark/intel-tdx/pccs-admin-tool:latest)
  --fetch-only              Stop after fetch (don't insert into PCCS)
  -h, --help                Show this help

Environment variables:
  INTEL_PCS_API_KEY         Intel PCS API subscription key
  PCCS_ADMIN_TOKEN          PCCS admin token (plaintext)
  PCS_CLIENT_IMAGE          Override PCS Client Tool container image
  ADMIN_TOOL_IMAGE          Override PCCS Admin Tool container image
  WORK_DIR                  Override working directory

Workflow:
  On the internet-connected side:
    1. Transfer host_*.csv files from TDX hosts (via sneakernet)
    2. Run: $(basename "$0") collect ./csv-dir/
    3. Run: $(basename "$0") fetch --api-key YOUR_KEY
    4. Transfer collateral-output/platform_collaterals.json to disconnected side

  On the disconnected side:
    5. Run: $(basename "$0") insert https://pccs-host:8081 --admin-token TOKEN

  Or all at once (single-server testing):
    $(basename "$0") full ./csv-dir/ https://127.0.0.1:8081 \\
      --api-key YOUR_KEY --admin-token TOKEN
EOF
    exit 0
}

INTEL_PCS_API_KEY="${INTEL_PCS_API_KEY:-}"
PCCS_ADMIN_TOKEN="${PCCS_ADMIN_TOKEN:-}"
FETCH_ONLY=false

POSITIONAL=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --api-key) INTEL_PCS_API_KEY="$2"; shift 2 ;;
        --admin-token) PCCS_ADMIN_TOKEN="$2"; shift 2 ;;
        --work-dir) WORK_DIR="$2"; shift 2 ;;
        --pcs-client-image) PCS_CLIENT_IMAGE="$2"; shift 2 ;;
        --admin-tool-image) ADMIN_TOOL_IMAGE="$2"; shift 2 ;;
        --fetch-only) FETCH_ONLY=true; shift ;;
        -h|--help) usage ;;
        collect|fetch|insert|full) POSITIONAL+=("$1"); shift ;;
        *) POSITIONAL+=("$1"); shift ;;
    esac
done

set -- "${POSITIONAL[@]}"

if [[ $# -eq 0 ]]; then
    usage
fi

COMMAND="$1"
shift

mkdir -p "$WORK_DIR"

do_collect() {
    local csv_dir="$1"

    if [[ ! -d "$csv_dir" ]]; then
        echo "ERROR: CSV directory not found: $csv_dir"
        exit 1
    fi

    local csv_count
    csv_count=$(find "$csv_dir" -name '*.csv' -type f | wc -l)
    if [[ "$csv_count" -eq 0 ]]; then
        echo "ERROR: No .csv files found in $csv_dir"
        echo "Run 'sudo PCKIDRetrievalTool -f host_\$(hostname).csv' on each TDX host first."
        exit 1
    fi

    echo "Found $csv_count CSV file(s) in $csv_dir"
    find "$csv_dir" -name '*.csv' -type f -exec basename {} \;

    echo ""
    echo "Merging CSV files into platform_list.json..."
    chmod 777 "$(realpath "$WORK_DIR")"
    podman run --rm \
        -v "$(realpath "$csv_dir"):/data:Z" \
        -v "$(realpath "$WORK_DIR"):/output:Z" \
        -w /opt/app-root/src/confidential-computing.tee.dcap/tools/PcsClientTool \
        "$PCS_CLIENT_IMAGE" \
        python3 pcsclient.py collect -d /data -o /output/platform_list.json

    if [[ -f "$WORK_DIR/platform_list.json" ]]; then
        echo ""
        echo "Created: $WORK_DIR/platform_list.json"
        local platform_count
        platform_count=$(python3 -c "
import json
data = json.load(open('$WORK_DIR/platform_list.json'))
print(len(data) if isinstance(data, list) else len(data.get('platforms', [])))
" 2>/dev/null || echo "?")
        echo "Platforms: $platform_count"
    else
        echo "ERROR: platform_list.json was not created"
        exit 1
    fi
}

do_fetch() {
    if [[ ! -f "$WORK_DIR/platform_list.json" ]]; then
        echo "ERROR: $WORK_DIR/platform_list.json not found"
        echo "Run 'collect' first to merge CSV files."
        exit 1
    fi

    if [[ -z "$INTEL_PCS_API_KEY" ]]; then
        echo "ERROR: Intel PCS API key required."
        echo "Set INTEL_PCS_API_KEY or use --api-key"
        echo ""
        echo "Get a free key at: https://api.portal.trustedservices.intel.com/manage-subscriptions"
        exit 1
    fi

    echo "Fetching collateral from Intel PCS..."
    echo "(This contacts api.trustedservices.intel.com)"
    echo ""

    # The PCS Client Tool normally prompts for the API key interactively.
    # We pass it via the PCCS_API_KEY env var to avoid interactive prompts.
    chmod 777 "$(realpath "$WORK_DIR")"
    podman run --rm \
        -v "$(realpath "$WORK_DIR"):/output:Z" \
        -e "PCCS_API_KEY=$INTEL_PCS_API_KEY" \
        -w /opt/app-root/src/confidential-computing.tee.dcap/tools/PcsClientTool \
        "$PCS_CLIENT_IMAGE" \
        python3 pcsclient.py fetch \
            -i /output/platform_list.json \
            -o /output/platform_collaterals.json

    if [[ -f "$WORK_DIR/platform_collaterals.json" ]]; then
        local size
        size=$(du -h "$WORK_DIR/platform_collaterals.json" | awk '{print $1}')
        echo ""
        echo "Collateral fetched successfully: $WORK_DIR/platform_collaterals.json ($size)"
        echo ""
        echo "Next step: transfer this file to the disconnected enclave and run:"
        echo "  $(basename "$0") insert <pccs-url> --admin-token TOKEN"
    else
        echo "ERROR: platform_collaterals.json was not created"
        echo "Check the PCS Client Tool output above for errors."
        exit 1
    fi
}

do_insert() {
    local pccs_url="$1"

    if [[ ! -f "$WORK_DIR/platform_collaterals.json" ]]; then
        echo "ERROR: $WORK_DIR/platform_collaterals.json not found"
        echo "Run 'fetch' first or transfer the file from the connected side."
        exit 1
    fi

    if [[ -z "$PCCS_ADMIN_TOKEN" ]]; then
        echo "ERROR: PCCS admin token required."
        echo "Set PCCS_ADMIN_TOKEN or use --admin-token"
        exit 1
    fi

    # Normalize URL — ensure it ends with the right path
    local insert_url="$pccs_url"
    if [[ "$insert_url" != */platformcollateral ]]; then
        insert_url="${insert_url%/}/sgx/certification/v4/platformcollateral"
    fi

    echo "Inserting collateral into PCCS at: $insert_url"
    echo ""

    # The admin tool normally prompts for the admin token.
    # We pipe it via stdin.
    echo "$PCCS_ADMIN_TOKEN" | podman run --rm -i \
        -v "$(realpath "$WORK_DIR")/platform_collaterals.json:/data/platform_collaterals.json:Z" \
        --network host \
        -w /opt/app-root/src/confidential-computing.tee.dcap.pccs/PccsAdminTool \
        "$ADMIN_TOOL_IMAGE" \
        python3 pccsadmin.py put --no-pccs-cert-check \
            -u "$insert_url" \
            -i /data/platform_collaterals.json

    echo ""
    echo "Collateral inserted successfully."
    echo ""
    echo "Verify PCCS is serving collateral:"
    echo "  curl -sk ${pccs_url%/}/sgx/certification/v4/rootcacrl"
}

case "$COMMAND" in
    collect)
        if [[ $# -lt 1 ]]; then
            echo "Usage: $(basename "$0") collect <csv-directory>"
            exit 1
        fi
        do_collect "$1"
        ;;
    fetch)
        do_fetch
        ;;
    insert)
        if [[ $# -lt 1 ]]; then
            echo "Usage: $(basename "$0") insert <pccs-url>"
            exit 1
        fi
        do_insert "$1"
        ;;
    full)
        if [[ $# -lt 2 ]]; then
            echo "Usage: $(basename "$0") full <csv-directory> <pccs-url>"
            exit 1
        fi
        CSV_DIR="$1"
        PCCS_URL="$2"

        echo "=== Step 1: Collect CSV files ==="
        do_collect "$CSV_DIR"
        echo ""
        echo "=== Step 2: Fetch from Intel PCS ==="
        do_fetch
        if ! $FETCH_ONLY; then
            echo ""
            echo "=== Step 3: Insert into PCCS ==="
            do_insert "$PCCS_URL"
        fi
        ;;
    *)
        echo "Unknown command: $COMMAND"
        usage
        ;;
esac
