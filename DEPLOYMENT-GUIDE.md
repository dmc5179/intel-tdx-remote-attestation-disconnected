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

### PCKCIDRT on OpenShift CoreOS

OpenShift bare-metal nodes run CoreOS, which does not support `dnf install`.
Options for running PCKCIDRT on CoreOS nodes:

1. **Pre-install during host provisioning** — run PCKCIDRT before CoreOS is
   deployed. Collect all CSV files during initial hardware staging.
2. **Boot from RHEL live media** — temporarily boot the host from RHEL
   installation media, install and run PCKCIDRT, collect the CSV, then reboot
   into CoreOS. The CSV is a one-time artifact.
3. **Privileged debug pod** — use `oc debug node/<node>` with `chroot /host`
   to access the host filesystem. The SGX device nodes may be accessible, but
   UEFI variable access is unreliable from within a container.

Option 1 (pre-install) is recommended for production deployments. Option 2 is
acceptable for brownfield environments where hosts are already running CoreOS.

---

## Prerequisites

Before starting, ensure you have:

- [ ] An **Intel PCS API subscription key** from [api.portal.trustedservices.intel.com](https://api.portal.trustedservices.intel.com/manage-subscriptions) (free)
- [ ] **Podman** (or Docker) on the internet-connected build host
- [ ] Access to a **container registry** (e.g., `quay.io`) from the connected side, or willingness to transfer image tarballs
- [ ] The `sgx-pck-id-retrieval-tool` RPM installed on each TDX host in the disconnected enclave
- [ ] A **sneakernet mechanism** (USB drive, write-once media, data diode) to transfer files between sides
- [ ] TDX hosts with Intel TDX enabled in BIOS and the SGX provisioning driver loaded

### RHEL Host Setup

On the host(s) where you will run the containers, install Podman:

```bash
sudo dnf install -y podman
```

No other packages are required — all tooling runs inside containers.

### PCCS Configuration

Before building (or after, by mounting a config file), you must configure
`pccs-config.json` with authentication token hashes. The PCCS uses SHA-512
hashes to authenticate API callers:

```bash
# Choose passwords for the user and admin tokens
echo -n 'your-user-token' | sha512sum | awk '{print $1}'
echo -n 'your-admin-token' | sha512sum | awk '{print $1}'
```

Replace the `UserTokenHash` and `AdminTokenHash` values in `pccs-config.json`
with the 128-character hex strings produced above. Keep the plaintext tokens —
the PCS Client Tool and Admin Tool will prompt for them at runtime.

### Single-Server Testing (No Air Gap)

If you do not have a physically separated disconnected environment, you can run
both the internet-connected side and the disconnected side on the same RHEL
server. The separation is logical (different containers), not physical:

- The PCS Client Tool container reaches Intel PCS over the internet
- The PCCS container runs in OFFLINE mode on the same host
- The PCCS Admin Tool connects to PCCS on `127.0.0.1:8081`
- Skip all sneakernet transfer steps — files are already local

Everything else in this guide works identically.

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
  -w /opt/app-root/src/confidential-computing.tee.dcap/tools/PcsClientTool \
  quay.io/danclark/intel-tdx/pcs-client-tool:latest \
  python3 pcsclient.py collect -d /data -o /output/platform_list.json
```

This reads all `host_*.csv` files and produces `./output/platform_list.json`.

### 3.3 Fetch collateral from Intel PCS

```bash
podman run --rm -it \
  -v ./output:/output:Z \
  -w /opt/app-root/src/confidential-computing.tee.dcap/tools/PcsClientTool \
  quay.io/danclark/intel-tdx/pcs-client-tool:latest \
  python3 pcsclient.py fetch -i /output/platform_list.json -o /output/platform_collaterals.json
```

When prompted, enter your **Intel PCS API subscription key**.

This contacts `api.trustedservices.intel.com` and produces `./output/platform_collaterals.json` containing PCK Certificates and Quote Verification Collateral for all platforms.

### 3.4 Transfer to the disconnected enclave

Copy `./output/platform_collaterals.json` to removable media for transfer to the disconnected enclave.

---

## Step 4: Deploy Containers in the Disconnected Enclave

Deploy the PCCS and PCCS Admin Tool in the disconnected enclave using either [Podman on a local server](#option-a-podman) or [an OpenShift cluster](#option-b-openshift).

---

### Option A: Podman

#### 4A.1 Import container images

On the host that will run PCCS in the disconnected enclave:

```bash
podman load -i /media/sneakernet/pccs.tar
podman load -i /media/sneakernet/pccs-admin-tool.tar
```

#### 4A.2 Generate TLS certificates for PCCS

The PCCS requires TLS. Generate a self-signed certificate on the host:

```bash
mkdir -p ./pccs-ssl-key
openssl req -x509 -newkey rsa:4096 \
  -keyout ./pccs-ssl-key/private.pem -out ./pccs-ssl-key/file.crt \
  -days 3650 -nodes -subj "/CN=PCCS"
chmod 644 ./pccs-ssl-key/private.pem
```

> **Note:** The private key needs `644` permissions so the non-root container
> user (UID 1001) can read it. In production, use proper certificates from your
> PKI and restrict permissions appropriately.

#### 4A.3 Start PCCS in OFFLINE mode

The PCCS container needs a persistent volume for its SQLite database so that collateral survives container restarts.

```bash
podman volume create pccs-data

podman run -d \
  --name pccs \
  --network host \
  -v pccs-data:/opt/intel/sgx-dcap-pccs/data:Z \
  -v ./pccs-ssl-key:/opt/intel/sgx-dcap-pccs/ssl_key:Z \
  quay.io/danclark/intel-tdx/pccs:latest
```

> **Note:** `--network host` is used instead of `-p 8081:8081` so that PCCS is
> reachable from other hosts. With rootless Podman, `-p` port mapping only binds
> to localhost. See [Firewall and Network Configuration](#4a6-firewall-and-network-configuration)
> for details.

Verify it is running:

```bash
podman logs pccs
# Should show: "HTTPS Server is running on: https://localhost:8081"

# Use 127.0.0.1 (not localhost) — podman maps ports on IPv4 only
curl -sk https://127.0.0.1:8081/sgx/certification/v4/rootcacrl
# Expected: 404 "No cache data" (empty cache is normal before collateral insert)
```

#### 4A.4 Insert collateral into PCCS

Copy `platform_collaterals.json` to the PCCS host, then run the Admin Tool:

```bash
podman run --rm -it \
  -v ./platform_collaterals.json:/data/platform_collaterals.json:Z \
  --network host \
  -w /opt/app-root/src/confidential-computing.tee.dcap.pccs/PccsAdminTool \
  quay.io/danclark/intel-tdx/pccs-admin-tool:latest \
  python3 pccsadmin.py put --no-pccs-cert-check \
    -u https://127.0.0.1:8081/sgx/certification/v4/platformcollateral \
    -i /data/platform_collaterals.json
```

When prompted, enter the admin token (the plaintext of the `AdminTokenHash` you
configured in `pccs-config.json`).

#### 4A.5 Configure TDX hosts to use PCCS

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

#### 4A.6 Firewall and Network Configuration

The PCCS serves attestation collateral over HTTPS on **port 8081**. All TDX
hosts (and OpenShift nodes running CoCo workloads) must be able to reach this
port.

**Podman networking:** When running PCCS with rootless Podman, the default
`-p 8081:8081` port mapping only binds to `localhost`. To make PCCS reachable
from other hosts, use `--network host` instead:

```bash
podman run -d \
  --name pccs \
  --network host \
  -v pccs-data:/opt/intel/sgx-dcap-pccs/data:Z \
  -v ./pccs-ssl-key:/opt/intel/sgx-dcap-pccs/ssl_key:Z \
  quay.io/danclark/intel-tdx/pccs:latest
```

**Host firewall (firewalld):** If `firewalld` is active on the PCCS host, open
port 8081:

```bash
sudo firewall-cmd --permanent --add-port=8081/tcp
sudo firewall-cmd --reload
```

Verify with: `sudo firewall-cmd --list-ports`

If no firewall is active (check `sudo systemctl status firewalld`), no host-level
changes are needed.

**Cloud environments (AWS, Azure, GCP):** The cloud security group or network
security rules must allow inbound TCP 8081 from the TDX hosts or OpenShift
cluster. For example, on AWS:

- Open TCP 8081 inbound in the PCCS instance's Security Group
- Source: the OpenShift cluster's egress IP range or the VPC CIDR
- If the OpenShift cluster is outside the VPC, use the PCCS host's public IP
  and open 8081 from the cluster's public egress IPs

**iptables:** If the host uses raw iptables (no firewalld), verify the INPUT
chain default policy is ACCEPT, or add a rule:

```bash
sudo iptables -A INPUT -p tcp --dport 8081 -j ACCEPT
```

---

### Option B: OpenShift

Deploying on an OpenShift cluster inside the disconnected enclave provides high availability, persistent storage, and network accessibility for all TDX hosts.

#### 4B.1 Load container images into the disconnected environment

On a host in the disconnected enclave that has access to both the sneakernet media and the OpenShift cluster:

```bash
podman load -i /media/sneakernet/pccs.tar
podman load -i /media/sneakernet/pccs-admin-tool.tar
```

#### 4B.2 Push images to the OpenShift internal registry

Tag and push the images to the cluster's internal registry (or a mirror registry accessible within the enclave):

```bash
REGISTRY=default-route-openshift-image-registry.apps.<cluster_domain>
NAMESPACE=intel-pccs

oc new-project ${NAMESPACE} || oc project ${NAMESPACE}

podman login -u $(oc whoami) -p $(oc whoami -t) ${REGISTRY}

podman tag quay.io/danclark/intel-tdx/pccs:latest \
  ${REGISTRY}/${NAMESPACE}/pccs:latest
podman push ${REGISTRY}/${NAMESPACE}/pccs:latest

podman tag quay.io/danclark/intel-tdx/pccs-admin-tool:latest \
  ${REGISTRY}/${NAMESPACE}/pccs-admin-tool:latest
podman push ${REGISTRY}/${NAMESPACE}/pccs-admin-tool:latest
```

If using a separate mirror registry instead of the internal registry, substitute that registry's hostname and ensure the cluster has a pull secret configured for it.

#### 4B.3 Create the PCCS PersistentVolumeClaim

The PCCS SQLite database must survive pod restarts.

```bash
oc apply -f - <<'EOF'
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: pccs-data
  namespace: intel-pccs
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 1Gi
EOF
```

#### 4B.4 Deploy PCCS

```bash
oc apply -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: pccs
  namespace: intel-pccs
  labels:
    app: pccs
spec:
  replicas: 1
  selector:
    matchLabels:
      app: pccs
  template:
    metadata:
      labels:
        app: pccs
    spec:
      containers:
        - name: pccs
          image: image-registry.openshift-image-registry.svc:5000/intel-pccs/pccs:latest
          ports:
            - containerPort: 8081
              protocol: TCP
          env:
            - name: PCCS_MODE
              value: "OFFLINE"
          volumeMounts:
            - name: pccs-data
              mountPath: /opt/intel/sgx-dcap-pccs/data
      volumes:
        - name: pccs-data
          persistentVolumeClaim:
            claimName: pccs-data
EOF
```

#### 4B.5 Create the PCCS Service

Expose the PCCS pod within the cluster so the Admin Tool and TDX hosts can reach it:

```bash
oc apply -f - <<'EOF'
apiVersion: v1
kind: Service
metadata:
  name: pccs
  namespace: intel-pccs
spec:
  selector:
    app: pccs
  ports:
    - port: 8081
      targetPort: 8081
      protocol: TCP
  type: ClusterIP
EOF
```

#### 4B.6 Expose PCCS to the enclave network

TDX hosts outside the cluster need to reach the PCCS endpoint. Create a passthrough Route (preserves the TLS that PCCS terminates itself) or a NodePort service depending on your network:

**Option A: OpenShift Route (passthrough TLS)**

```bash
oc apply -f - <<'EOF'
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: pccs
  namespace: intel-pccs
spec:
  port:
    targetPort: 8081
  tls:
    termination: passthrough
  to:
    kind: Service
    name: pccs
EOF
```

The PCCS will be reachable at `https://pccs-intel-pccs.apps.<cluster_domain>:443`.

**Option B: NodePort**

```bash
oc apply -f - <<'EOF'
apiVersion: v1
kind: Service
metadata:
  name: pccs-nodeport
  namespace: intel-pccs
spec:
  selector:
    app: pccs
  ports:
    - port: 8081
      targetPort: 8081
      nodePort: 30081
      protocol: TCP
  type: NodePort
EOF
```

The PCCS will be reachable at `https://<any_node_ip>:30081`.

#### 4B.7 Verify the deployment

```bash
oc get pods -n intel-pccs
oc logs deployment/pccs -n intel-pccs

PCCS_URL=$(oc get route pccs -n intel-pccs -o jsonpath='{.spec.host}')
curl -k https://${PCCS_URL}/sgx/certification/v4/rootcacrl
```

#### 4B.8 Insert collateral into PCCS

Create a ConfigMap from the collateral file, then run the Admin Tool as a one-shot Job:

```bash
oc create configmap platform-collaterals \
  -n intel-pccs \
  --from-file=platform_collaterals.json=./platform_collaterals.json
```

```bash
oc apply -f - <<'EOF'
apiVersion: batch/v1
kind: Job
metadata:
  name: pccs-admin-insert
  namespace: intel-pccs
spec:
  backoffLimit: 2
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: pccs-admin
          image: image-registry.openshift-image-registry.svc:5000/intel-pccs/pccs-admin-tool:latest
          command:
            - python3
            - /opt/app-root/src/confidential-computing.tee.dcap.pccs/PccsAdminTool/pccsadmin.py
            - put
            - -u
            - https://pccs.intel-pccs.svc:8081/sgx/certification/v4/platformcollateral
            - -i
            - /data/platform_collaterals.json
          volumeMounts:
            - name: collaterals
              mountPath: /data
              readOnly: true
      volumes:
        - name: collaterals
          configMap:
            name: platform-collaterals
EOF
```

Check that the Job completed:

```bash
oc get jobs -n intel-pccs
oc logs job/pccs-admin-insert -n intel-pccs
```

To refresh collateral later (see [Collateral Refresh](#collateral-refresh)), delete the old ConfigMap and Job, then recreate both with the new file:

```bash
oc delete job pccs-admin-insert -n intel-pccs
oc delete configmap platform-collaterals -n intel-pccs
# Then repeat the configmap create + job apply above with the new file
```

#### 4B.9 Configure TDX hosts to use PCCS

On each TDX host in the enclave, configure the QCNL (Quote Configuration and Negotiation Library) to point at the PCCS service on OpenShift.

Edit `/etc/sgx_default_qcnl.conf`:

**If using an OpenShift Route (from step 4B.6):**

```json
{
  "pccs_url": "https://pccs-intel-pccs.apps.<cluster_domain>/sgx/certification/v4/",
  "use_secure_cert": false,
  "collateral_service": "https://pccs-intel-pccs.apps.<cluster_domain>/sgx/certification/v4/"
}
```

**If using NodePort (from step 4B.6):**

```json
{
  "pccs_url": "https://<node_ip>:30081/sgx/certification/v4/",
  "use_secure_cert": false,
  "collateral_service": "https://<node_ip>:30081/sgx/certification/v4/"
}
```

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

## FIPS Considerations

When deploying in a FIPS-enabled environment:

- **PCCS (Node.js):** PCCS is a Node.js application. Node.js is not
  FIPS-validated by Red Hat. If your security policy requires all services to run
  FIPS-validated cryptographic modules, deploy PCCS on a host outside the FIPS
  enforcement boundary or document the exception.
- **TLS certificates:** Ensure any TLS certificates generated for PCCS use
  FIPS-approved algorithms (RSA-2048 or higher, ECDSA with NIST P-256 or P-384).
  Avoid SHA-1 signatures.
- **PCCS Admin Tool:** The admin tool uses Python `requests` with urllib3.
  Python's `ssl` module respects the system FIPS mode on RHEL but the tool itself
  has not been independently FIPS-certified. Verify that TLS connections between
  the admin tool and PCCS negotiate FIPS-approved cipher suites.

---

## TCB Recovery

If Intel releases a microcode or firmware update that changes TCB components on any TDX host:

1. Apply the update on the affected hosts.
2. Perform an **SGX Factory Reset** in BIOS on the affected hosts.
3. Re-run PCKCIDRT to generate new `.csv` files.
4. Follow the full flow from Step 2 onward — the platform must be re-registered with Intel PCS to obtain new PCK Certificates matching the updated TCB.

> **Note:** Indirect Registration is a one-way commitment. Once a platform has been indirectly registered, switching to Direct Registration requires an SGX Factory Reset to generate new shared platform keys.
