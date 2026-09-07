# Connecting to the Intel PCS API (Connected Side)

This page covers how the internet-connected RHEL server fetches attestation
collateral from Intel's public Provisioning Certification Service (PCS).

## Overview

The PCS Client Tool runs on the connected side and performs two operations:

1. **Collect** — merges per-host CSV files into a single `platform_list.json`
2. **Fetch** — contacts Intel PCS to download PCK certificates and quote
   verification collateral for all platforms

```
  TDX Host CSVs                  Intel PCS API
  (via sneakernet)               (api.trustedservices.intel.com)
       │                                  │
       ▼                                  │
  ┌──────────────┐                        │
  │ PCS Client   │  ── HTTPS request ────►│
  │ Tool         │  ◄── PCK certs ────────│
  │ (container)  │  ◄── collateral ───────│
  └──────────────┘
       │
       ▼
  platform_collaterals.json
  (transfer to disconnected side)
```

## Prerequisites

- Container images built (see [Connected Server Setup](connected-server-setup.md))
- Intel PCS API subscription key
- CSV files from all TDX hosts (transferred from the disconnected side)

## Step 1: Place CSV Files

Transfer the `host_*.csv` files from the disconnected enclave to the connected
server:

```bash
mkdir -p ./platform-data
cp /media/sneakernet/host_*.csv ./platform-data/
```

Each CSV file contains the Platform Manifest and platform identification data
(PPID, CPUSVN, PCESVN, PCEID, QE_ID) from one TDX host.

## Step 2: Collect (Merge CSV Files)

### Automated

```bash
./scripts/fetch-platform-collateral.sh collect ./platform-data/
```

### Manual

```bash
podman run --rm \
  -v ./platform-data:/data:Z \
  -v ./output:/output:Z \
  -w /opt/app-root/src/confidential-computing.tee.dcap/tools/PcsClientTool \
  quay.io/danclark/intel-tdx/pcs-client-tool:latest \
  python3 pcsclient.py collect -d /data -o /output/platform_list.json
```

This reads all CSV files and produces `platform_list.json`.

## Step 3: Fetch Collateral from Intel PCS

### Automated

```bash
export INTEL_PCS_API_KEY=your-api-key
./scripts/fetch-platform-collateral.sh fetch
```

Or with the key inline:

```bash
./scripts/fetch-platform-collateral.sh fetch --api-key your-api-key
```

### Manual

The PCS Client Tool prompts interactively for the API key. When running
non-interactively, pipe the answers via stdin:

```bash
printf '%s\nn\nn\n' "$INTEL_PCS_API_KEY" | podman run --rm -i \
  -v ./output:/output:Z \
  -w /opt/app-root/src/confidential-computing.tee.dcap/tools/PcsClientTool \
  quay.io/danclark/intel-tdx/pcs-client-tool:latest \
  python3 pcsclient.py fetch \
    -i /output/platform_list.json \
    -o /output/platform_collaterals.json
```

The three piped values are:
1. The API key (read by `getpass`)
2. `n` — decline saving the key to the OS keyring
3. `n` — decline saving a list of unavailable certificates

### What gets fetched

The tool contacts `api.trustedservices.intel.com` and downloads:

| Data | Purpose |
|------|---------|
| PCK Certificates | Platform-specific signing certificates for each TDX host |
| Root CA CRL | Certificate revocation list for the Intel root CA |
| PCK CRL | Revocation list for PCK certificates |
| QE Identity | Quoting Enclave identity for quote verification |
| TCB Info | Trusted Computing Base levels for the platform |

All data is bundled into `platform_collaterals.json` (~500 KB for 2 platforms).

## Step 4: Transfer to the Disconnected Enclave

Copy `platform_collaterals.json` to removable media:

```bash
cp ./collateral-output/platform_collaterals.json /media/sneakernet/
```

This file is the only artifact that needs to cross the air gap for collateral
(container images are a separate, less frequent transfer).

## All-in-One (Single Server Testing)

If the connected and disconnected sides are the same machine (no physical air
gap), run the full pipeline:

```bash
./scripts/fetch-platform-collateral.sh full ./platform-data/ https://127.0.0.1:8081 \
  --api-key YOUR_KEY --admin-token my-admin-token
```

This runs collect, fetch, and insert in sequence.

## Collateral Refresh

Collateral expires ~30 days after download. To refresh:

1. Re-run `fetch` — no need to re-collect CSVs unless hardware has changed
2. Transfer the new `platform_collaterals.json` across the air gap
3. Re-run `insert` on the disconnected side

```bash
./scripts/fetch-platform-collateral.sh fetch --api-key YOUR_KEY
```

## Troubleshooting

### "401 Unauthorized" from Intel PCS

- Verify your API key is correct
- Check that your subscription is active at
  [api.portal.trustedservices.intel.com](https://api.portal.trustedservices.intel.com/manage-subscriptions)

### "Some certificates are Not available"

This is normal for platforms registered via indirect registration when Intel
hasn't processed the platform manifest yet. The tool will still fetch
available certificates. Re-run after a few hours if needed.

### Empty or Missing `platform_collaterals.json`

- Verify `platform_list.json` exists and contains platform entries
- Check the PCS Client Tool output for network errors
- Ensure the connected server can reach `api.trustedservices.intel.com:443`
