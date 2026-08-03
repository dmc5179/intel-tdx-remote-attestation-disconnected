# Intel TDX Remote Attestation: Disconnected Deployment Guide

This guide walks through deploying Intel TDX remote attestation infrastructure across an internet-connected side and a disconnected (air-gapped) enclave using the **PCCS-based indirect registration** flow.

All tooling except the PCK Cert ID Retrieval Tool runs in containers.

## Architecture Overview

```
  INTERNET-CONNECTED SIDE                    DISCONNECTED ENCLAVE
 ========================                   ======================

 +---------------------+                    +-------------------+
 | PCS Client Tool     |                    | TDX Host A        |
 | (container)         |                    | - PCKCIDRT (RPM)  |
 |                     |                    +-------------------+
 | Merges .csv files,  |   host_*.csv       +-------------------+
 | fetches collateral  | <----- sneakernet  | TDX Host B        |
 | from Intel PCS      |                    | - PCKCIDRT (RPM)  |
 |                     |                    +-------------------+
 | Outputs:            |                    +-------------------+
 | platform_collaterals|                    | TDX Host N        |
 |   .json             |                    | - PCKCIDRT (RPM)  |
 +---------------------+                    +-------------------+
         |                                          |
         | platform_collaterals.json                |
         | + container image tarballs               | queries
         |                                          v
         +--- sneakernet ------>  +----------------------------+
                                  | PCCS (container)           |
                                  | Node.js, OFFLINE mode      |
                                  | Port 8081                  |
                                  +----------------------------+
                                          ^
                                          | inserts collateral
                                  +----------------------------+
                                  | PCCS Admin Tool (container)|
                                  +----------------------------+
```

### Component Summary

| Component | Side | Containerized? | Purpose |
|-----------|------|---------------|---------|
| PCS Client Tool | Connected | Yes | Merges platform `.csv` files, fetches PCK certs and collateral from Intel PCS |
| PCCS | Disconnected | Yes | Caches attestation collateral, serves it to TDX hosts for quote generation |
| PCCS Admin Tool | Disconnected | Yes | Inserts collateral into the PCCS database |
| PCK Cert ID Retrieval Tool (PCKCIDRT) | Disconnected | **No** | Extracts Platform Manifest from each TDX host's hardware |

---

## Why PCKCIDRT Cannot Be Containerized

The PCK Cert ID Retrieval Tool (PCKCIDRT) must run directly on bare metal for the following reasons:

1. **Direct SGX hardware access required.** The tool communicates with SGX hardware through device nodes (`/dev/sgx_provision`, `/dev/sgx_enclave`) and reads the Platform Manifest from UEFI variables exposed by the BIOS. Containers do not have reliable access to UEFI variable stores.

2. **UEFI variable side effect.** When PCKCIDRT successfully retrieves the Platform Manifest, it sets a one-time bit in a UEFI variable that tells the BIOS to stop presenting the Platform Manifest on subsequent boots. This UEFI write requires bare-metal privilege. An **SGX Factory Reset** in BIOS is required to re-run it.

3. **Root privilege on the physical host.** The tool must run as `root` on the physical TDX server to access the SGX provisioning interface.

4. **One-shot operation.** PCKCIDRT only needs to run once per host (or once after each SGX Factory Reset). There is no operational benefit to containerizing a one-shot bare-metal tool.

Install the tool from the Intel SGX RPM repository:

```bash
sudo dnf install -y sgx-pck-id-retrieval-tool
```

---

## Prerequisites

Before starting, ensure you have:

- [ ] An **Intel PCS API subscription key** from [api.portal.trustedservices.intel.com](https://api.portal.trustedservices.intel.com/manage-subscriptions) (free)
- [ ] **Podman** (or Docker) on the internet-connected build host
- [ ] Access to a **container registry** (e.g., `quay.io`) from the connected side, or willingness to transfer image tarballs
- [ ] The `sgx-pck-id-retrieval-tool` RPM installed on each TDX host in the disconnected enclave
- [ ] A **sneakernet mechanism** (USB drive, write-once media, data diode) to transfer files between sides
- [ ] TDX hosts with Intel TDX enabled in BIOS and the SGX provisioning driver loaded

---

## Step 1: Build All Container Images (Internet-Connected Side)

All container images must be built on the internet-connected side where GitHub, PyPI, and container base images are reachable.

### 1.1 Build the images

```bash
./build.sh
```

This builds four images:

| Image | Containerfile | Runs on |
|-------|--------------|---------|
| `pcs-base` | `PCS-Base-Containerfile` | Base layer only (not run directly) |
| `pcs-client-tool` | `PCS-Client-Tool-Containerfile` | Connected side |
| `pccs-admin-tool` | `PCCS-Admin-Tool-Containerfile` | Disconnected enclave |
| `pccs` | `PCCS-Containerfile` | Disconnected enclave |

### 1.2 Export images for transfer to the disconnected enclave

The build script automatically exports tarballs into `./images/`:

```
images/
  pcs-client-tool.tar
  pccs-admin-tool.tar
  pccs.tar
```

Transfer the following to the disconnected enclave via sneakernet:

- `images/pccs.tar`
- `images/pccs-admin-tool.tar`

The `pcs-client-tool.tar` stays on the connected side.

---

## Step 2: Collect Platform Data (Disconnected Enclave)

On **each TDX host** in the disconnected enclave, run the PCKCIDRT to extract the Platform Manifest.

### 2.1 Install the tool (if not already installed)

```bash
sudo dnf install -y sgx-pck-id-retrieval-tool
```

### 2.2 Generate the platform CSV

```bash
sudo PCKIDRetrievalTool -f host_$(hostnamectl --static).csv
```

This produces a file like `host_tdxserver01.csv` containing the Platform Manifest and platform identification data (PPID, CPUSVN, PCESVN, PCEID, QE_ID, Platform Manifest).

### 2.3 Collect all CSV files

Gather all `host_*.csv` files from every TDX host onto a single piece of removable media.

> **WARNING:** PCKCIDRT sets a UEFI bit that prevents the Platform Manifest from being presented again on subsequent boots. If you need to re-run it, you must perform an **SGX Factory Reset** in BIOS first. Handle the CSV files carefully — they are irreplaceable without a factory reset.

---

## Step 3: Fetch Collateral from Intel PCS (Internet-Connected Side)

Transfer the collected `host_*.csv` files to the internet-connected side.

### 3.1 Place CSV files in a working directory

```bash
mkdir -p ./platform-data
cp /media/sneakernet/host_*.csv ./platform-data/
```

### 3.2 Merge CSV files into a single platform list

```bash
podman run --rm \
  -v ./platform-data:/data:Z \
  -v ./output:/output:Z \
  -w /home/default/confidential-computing.tee.dcap/tools/PcsClientTool \
  quay.io/danclark/intel-tdx/pcs-client-tool:latest \
  python3 pcsclient.py collect -d /data -o /output/platform_list.json
```

This reads all `host_*.csv` files and produces `./output/platform_list.json`.

### 3.3 Fetch collateral from Intel PCS

```bash
podman run --rm -it \
  -v ./output:/output:Z \
  -w /home/default/confidential-computing.tee.dcap/tools/PcsClientTool \
  quay.io/danclark/intel-tdx/pcs-client-tool:latest \
  python3 pcsclient.py fetch -i /output/platform_list.json -o /output/platform_collaterals.json
```

When prompted, enter your **Intel PCS API subscription key**.

This contacts `api.trustedservices.intel.com` and produces `./output/platform_collaterals.json` containing PCK Certificates and Quote Verification Collateral for all platforms.

### 3.4 Transfer to the disconnected enclave

Copy `./output/platform_collaterals.json` to removable media for transfer to the disconnected enclave.

---

## Step 4: Deploy Containers in the Disconnected Enclave

### 4.1 Import container images

On the host that will run PCCS in the disconnected enclave:

```bash
podman load -i /media/sneakernet/pccs.tar
podman load -i /media/sneakernet/pccs-admin-tool.tar
```

### 4.2 Start PCCS in OFFLINE mode

The PCCS container needs a persistent volume for its SQLite database so that collateral survives container restarts.

```bash
podman volume create pccs-data

podman run -d \
  --name pccs \
  -p 8081:8081 \
  -v pccs-data:/opt/intel/sgx-dcap-pccs/data:Z \
  -e PCCS_MODE=OFFLINE \
  quay.io/danclark/intel-tdx/pccs:latest
```

Verify it is running:

```bash
podman logs pccs
curl -k https://localhost:8081/sgx/certification/v4/rootcacrl
```

### 4.3 Insert collateral into PCCS

Copy `platform_collaterals.json` to the PCCS host, then run the Admin Tool:

```bash
podman run --rm \
  -v ./platform_collaterals.json:/data/platform_collaterals.json:Z \
  --network host \
  quay.io/danclark/intel-tdx/pccs-admin-tool:latest \
  python3 /home/default/confidential-computing.tee.dcap.pccs/PccsAdminTool/pccsadmin.py put \
    -u https://localhost:8081/sgx/certification/v4/platformcollateral \
    -i /data/platform_collaterals.json
```

### 4.4 Configure TDX hosts to use PCCS

On each TDX host in the enclave, configure the QCNL (Quote Configuration and Negotiation Library) to point at the PCCS container.

Edit `/etc/sgx_default_qcnl.conf`:

```json
{
  "pccs_url": "https://PCCS_HOST:8081/sgx/certification/v4/",
  "use_secure_cert": false,
  "collateral_service": "https://PCCS_HOST:8081/sgx/certification/v4/"
}
```

Replace `PCCS_HOST` with the hostname or IP of the machine running the PCCS container.

After this, TDX hosts can generate TD Quotes using the cached collateral without any internet access.

---

## Containers in the Disconnected Enclave

Two containers run inside the disconnected enclave:

| Container | When It Runs | Purpose |
|-----------|-------------|---------|
| **PCCS** | Continuously (long-running service) | Serves cached attestation collateral to all TDX hosts over HTTPS on port 8081 |
| **PCCS Admin Tool** | On-demand (run-and-exit) | Inserts or refreshes `platform_collaterals.json` into the PCCS database |

The PCCS container must be accessible over the enclave network from all TDX hosts.

---

## Data Transfer Summary

### From Disconnected Enclave to Connected Side

| What | Format | Source | Sensitivity |
|------|--------|--------|-------------|
| Platform Manifest + IDs | `host_<hostname>.csv` (one per TDX host) | PCKCIDRT on each bare-metal host | Contains encrypted platform keys. Handle securely. |

### From Connected Side to Disconnected Enclave

| What | Format | Source | Sensitivity |
|------|--------|--------|-------------|
| PCK Certs + Verification Collateral | `platform_collaterals.json` | PCS Client Tool (from Intel PCS) | Contains platform-specific certificates. Handle securely. |
| PCCS container image | `pccs.tar` | `podman save` | Software artifact |
| PCCS Admin Tool container image | `pccs-admin-tool.tar` | `podman save` | Software artifact |

Container image tarballs only need to be transferred once (or when updated). The `platform_collaterals.json` must be refreshed periodically.

---

## Collateral Refresh

Quote Verification Collateral contains a `nextUpdate` field — currently set to **30 days** from download. After expiration, quote verification will fail.

To refresh:

1. On the **connected side**, re-run the `pcs-client-tool fetch` command (Step 3.3). No need to re-collect CSV files — the `platform_list.json` from the initial run is still valid.
2. Transfer the new `platform_collaterals.json` to the disconnected enclave.
3. Re-run the PCCS Admin Tool `put` command (Step 4.3) to update the PCCS cache.

You do **not** need to re-run PCKCIDRT on the TDX hosts unless there has been a TCB change (firmware or microcode update). If TCB has changed, re-registration is required — see "Adding New Hosts" below.

---

## Adding New Hosts

To add a new TDX host to the enclave:

1. Install `sgx-pck-id-retrieval-tool` on the new host.
2. Run `sudo PCKIDRetrievalTool -f host_$(hostnamectl --static).csv`.
3. Transfer the new `.csv` file to the connected side.
4. Place it alongside any existing `.csv` files and re-run:
   ```bash
   pcs-client-tool collect -d /path/to/all/csvs
   pcs-client-tool fetch
   ```
5. Transfer the updated `platform_collaterals.json` back to the enclave.
6. Re-run the PCCS Admin Tool `put` command to insert the updated collateral.
7. Configure QCNL on the new host to point at the PCCS (Step 4.4).

---

## TCB Recovery

If Intel releases a microcode or firmware update that changes TCB components on any TDX host:

1. Apply the update on the affected hosts.
2. Perform an **SGX Factory Reset** in BIOS on the affected hosts.
3. Re-run PCKCIDRT to generate new `.csv` files.
4. Follow the full flow from Step 2 onward — the platform must be re-registered with Intel PCS to obtain new PCK Certificates matching the updated TCB.

> **Note:** Indirect Registration is a one-way commitment. Once a platform has been indirectly registered, switching to Direct Registration requires an SGX Factory Reset to generate new shared platform keys.
