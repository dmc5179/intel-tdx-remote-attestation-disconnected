# Connecting PCCS to OpenShift (Disconnected Side)

This page covers how to configure the disconnected PCCS to serve attestation
collateral to OpenShift nodes running CoCo workloads, and how to configure the
KBS (Trustee) to verify TDX quotes using PCCS-provided collateral.

## Architecture

```
  OpenShift Cluster (disconnected)           RHEL Server (disconnected)
 ====================================       ==========================

 ┌─────────────────────────────────┐        ┌──────────────────────┐
 │ kata-cc Pod (TDX VM)            │        │ PCCS Container       │
 │  ├── CDH → contacts KBS        │        │ Port 8081 (HTTPS)    │
 │  └── QGS → generates TD Quote  │        │ OFFLINE mode         │
 └─────────────────────────────────┘        │ SQLite collateral DB │
           │                                └──────────────────────┘
           │ attestation                             ▲
           ▼                                         │
 ┌─────────────────────────────────┐                 │
 │ KBS (Trustee)                   │                 │
 │  └── DCAP verification library  │── HTTPS ────────┘
 │      fetches collateral from    │   (port 8081)
 │      PCCS to verify TDX quote   │
 └─────────────────────────────────┘
```

Two things need to reach PCCS:
1. **KBS** — to verify TDX quotes during attestation
2. **QGS DaemonSet** (Intel DCAP operator) — to generate TD Quotes (if using
   on-cluster PCCS; the operator can also use local PCK cert cache)

## Option A: PCCS on the Disconnected RHEL Server (Podman)

If PCCS runs on the disconnected RHEL server (not on OpenShift), the OpenShift
cluster must be able to reach it over the enclave network.

### Firewall Configuration

Open port 8081 on the PCCS host:

```bash
# firewalld
sudo firewall-cmd --permanent --add-port=8081/tcp
sudo firewall-cmd --reload

# Or iptables
sudo iptables -A INPUT -p tcp --dport 8081 -j ACCEPT
```

Verify: `sudo firewall-cmd --list-ports`

### Cloud Environments (AWS, Azure, GCP)

If the PCCS host is in a cloud VPC, update the security group:

- **Inbound rule:** TCP 8081 from the OpenShift cluster's egress CIDR
- Example: `66.187.232.0/24` → TCP 8081

### Verify Connectivity from OpenShift

From a node or debug pod:

```bash
curl -sk https://<pccs-host-ip>:8081/sgx/certification/v4/rootcacrl
```

Should return hex-encoded CRL data (not 404 or connection refused).

## Option B: PCCS on OpenShift (Helm Chart)

If PCCS runs on OpenShift via the Helm chart, it's already accessible within
the cluster via the ClusterIP service. External TDX hosts need a NodePort or
Route.

### Internal Access (ClusterIP)

```
https://pccs.intel-pccs.svc:8081
```

This is what KBS uses — no additional configuration needed for in-cluster
access.

### External Access (NodePort)

The Helm chart creates a NodePort on port 30081 by default:

```
https://<any-node-ip>:30081
```

### External Access (Route)

For HTTPS passthrough via the OpenShift router:

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

PCCS is then reachable at `https://pccs-intel-pccs.apps.<cluster_domain>:443`.

## Configure KBS (Trustee) to Use PCCS

KBS needs to reach PCCS to fetch collateral for TDX quote verification. This
is configured via a QCNL config secret.

### Create the QCNL Config Secret

```bash
cat > /tmp/sgx_default_qcnl.conf <<EOF
{
  "pccs_url": "https://<pccs-host-or-service>:8081/sgx/certification/v4/",
  "use_secure_cert": false,
  "collateral_service": "https://<pccs-host-or-service>:8081/sgx/certification/v4/"
}
EOF

oc create secret generic kbs-qcnl-config \
  -n trustee-operator-system \
  --from-file=sgx_default_qcnl.conf=/tmp/sgx_default_qcnl.conf
```

Replace `<pccs-host-or-service>` with:
- **Podman PCCS:** the RHEL server's IP or hostname (e.g., `10.0.0.50`)
- **On-cluster PCCS (ClusterIP):** `pccs.intel-pccs.svc`
- **On-cluster PCCS (NodePort):** any node IP with port `30081`

### Configure KbsConfig CR

Set the QCNL config and environment variable on the KbsConfig CR:

```bash
oc patch kbsconfig kbsconfig -n trustee-operator-system --type=merge -p '{
  "spec": {
    "kbsLocalCertCacheSpec": {
      "secretName": "kbs-qcnl-config",
      "mountPath": "/run/qcnl"
    },
    "KbsEnvVars": {
      "QCNL_CONF_PATH": "/run/qcnl/sgx_default_qcnl.conf"
    }
  }
}'
```

This mounts the QCNL config into the KBS pod and tells the DCAP verification
library where to find it.

### Verify KBS Can Reach PCCS

After the KBS pod restarts, check its logs during an attestation attempt:

```bash
oc logs -n trustee-operator-system -l app=kbs -c kbs --tail=30
```

Successful collateral fetch shows no QCNL errors. A failed connection shows:

```
ERROR: sgx_qcnl_get_pck_cert_chain: Cannot connect to PCCS
```

## Configure TDX Hosts to Use PCCS

If bare-metal TDX hosts in the enclave need direct PCCS access (outside of
OpenShift), configure their QCNL:

Edit `/etc/sgx_default_qcnl.conf`:

```json
{
  "pccs_url": "https://<pccs-host>:8081/sgx/certification/v4/",
  "use_secure_cert": false,
  "collateral_service": "https://<pccs-host>:8081/sgx/certification/v4/"
}
```

Set `"use_secure_cert": false` because PCCS uses a self-signed certificate.

## Intel DCAP Operator (QGS) and PCCS

The Intel TDX DCAP operator manages the QGS (Quote Generation Service). By
default, the operator does **not** use the PCCS QCNL endpoint. Instead:

1. An init container collects the platform manifest from the host
2. A registrar watches for platform secrets and fetches PCK certs from Intel PCS
   (or from a local cache if pre-populated)
3. A sidecar writes the PCK certs to `/run/dcap/cache/` in the QGS pod
4. QGS reads PCK certs from the local cache, not from PCCS

The operator overrides the QGS QCNL config via a pod annotation:

```json
{"local_cache_only": true}
```

This means QGS does not require network connectivity to PCCS for quote
generation. PCCS is needed primarily by **KBS** for quote **verification**.

## Network Requirements Summary

| Source | Destination | Port | Protocol | Purpose |
|--------|-------------|------|----------|---------|
| KBS pod | PCCS | 8081 | HTTPS | Fetch collateral for TDX quote verification |
| Admin Tool | PCCS | 8081 | HTTPS | Insert platform collateral |
| TDX hosts (optional) | PCCS | 8081 | HTTPS | Direct QCNL queries |

## Troubleshooting

### KBS attestation fails with collateral error

- Verify the QCNL secret is mounted: `oc exec <kbs-pod> -c kbs -- cat /run/qcnl/sgx_default_qcnl.conf`
- Verify `QCNL_CONF_PATH` env var is set: `oc exec <kbs-pod> -c kbs -- env | grep QCNL`
- Verify PCCS has collateral: `curl -sk https://<pccs>:8081/sgx/certification/v4/rootcacrl`

### PCCS returns 404 for all queries

- Collateral has not been inserted yet — run the Admin Tool insert step
- Collateral has expired — re-fetch from Intel PCS and re-insert

### KBS pod cannot reach PCCS host

- Check firewall rules on the PCCS host
- Check OpenShift egress network policies
- If using NodePort, ensure the node IP is routable from the KBS pod network
