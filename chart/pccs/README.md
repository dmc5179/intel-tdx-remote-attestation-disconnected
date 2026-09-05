# Intel PCCS Helm Chart for OpenShift

Deploys the Intel Provisioning Certificate Caching Service (PCCS) on OpenShift
for TDX/SGX remote attestation in disconnected environments.

PCCS runs in **OFFLINE** mode by default — collateral is inserted manually via
the Admin Tool rather than fetched from Intel PCS.

## Prerequisites

- OpenShift 4.x cluster with a default StorageClass (for the SQLite PVC)
- The PCCS container image pushed to an accessible registry
- Helm 3

## Quick Start

```bash
# 1. Generate token hashes (save the plaintext tokens — you'll need them for the Admin Tool)
USER_HASH=$(echo -n 'your-user-token' | sha512sum | awk '{print $1}')
ADMIN_HASH=$(echo -n 'your-admin-token' | sha512sum | awk '{print $1}')

# 2. Install
helm install pccs ./chart/pccs \
  -n intel-pccs --create-namespace \
  --set pccs.userTokenHash="$USER_HASH" \
  --set pccs.adminTokenHash="$ADMIN_HASH"

# 3. Verify
oc get pods -n intel-pccs
oc logs -n intel-pccs -l app=pccs
```

PCCS will be available at:
- **ClusterIP**: `https://pccs.intel-pccs.svc:8081` (from within the cluster)
- **NodePort**: `https://<node-ip>:30081` (from outside the cluster)

## Configuration

| Parameter | Description | Default |
|-----------|-------------|---------|
| `namespace` | Kubernetes namespace | `intel-pccs` |
| `image.repository` | PCCS container image | `quay.io/danclark/intel-tdx/pccs` |
| `image.tag` | Image tag | `latest` |
| `image.pullPolicy` | Image pull policy | `Always` |
| `pccs.httpsPort` | HTTPS listen port | `8081` |
| `pccs.cachingFillMode` | `OFFLINE` or `LAZY` or `REQ` | `OFFLINE` |
| `pccs.logLevel` | Log level | `info` |
| `pccs.userTokenHash` | SHA-512 hash of user token | `""` (required) |
| `pccs.adminTokenHash` | SHA-512 hash of admin token | `""` (required) |
| `tls.generate` | Auto-generate self-signed TLS cert | `true` |
| `tls.existingSecret` | Name of existing TLS secret (if `generate: false`) | `""` |
| `storage.size` | PVC size for SQLite database | `1Gi` |
| `storage.storageClass` | StorageClass name (empty = default) | `""` |
| `nodePort` | NodePort for external access (null = ClusterIP only) | `30081` |
| `resources.requests.cpu` | CPU request | `100m` |
| `resources.requests.memory` | Memory request | `256Mi` |
| `resources.limits.cpu` | CPU limit | `500m` |
| `resources.limits.memory` | Memory limit | `512Mi` |

## Custom Values File

For production use, create a `my-values.yaml`:

```yaml
image:
  repository: my-registry.example.com/intel-tdx/pccs
  tag: "1.0.0"
  pullPolicy: IfNotPresent

pccs:
  userTokenHash: "<sha512-hash>"
  adminTokenHash: "<sha512-hash>"
  cachingFillMode: OFFLINE

tls:
  generate: false
  existingSecret: pccs-custom-tls

storage:
  storageClass: my-storage-class

nodePort: null  # ClusterIP only
```

```bash
helm install pccs ./chart/pccs -n intel-pccs --create-namespace -f my-values.yaml
```

## TLS Configuration

By default the chart generates a self-signed certificate via an init container.
For production, provide your own TLS secret:

```bash
# Create the TLS secret
oc create secret tls pccs-custom-tls \
  -n intel-pccs \
  --cert=path/to/tls.crt \
  --key=path/to/tls.key

# Install with existing secret
helm install pccs ./chart/pccs -n intel-pccs --create-namespace \
  --set tls.generate=false \
  --set tls.existingSecret=pccs-custom-tls \
  --set pccs.userTokenHash="$USER_HASH" \
  --set pccs.adminTokenHash="$ADMIN_HASH"
```

## Loading Attestation Collateral

After PCCS is running, use the PCS Client Tool and Admin Tool to load
collateral. See the [Deployment Guide](../../DEPLOYMENT-GUIDE.md) for the full
attestation flow.

```bash
# From the Admin Tool container, point at the PCCS NodePort:
NODE_IP=$(oc get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')

# Insert platform collateral
podman run --rm -v ./collateral:/collateral:Z \
  quay.io/danclark/intel-tdx/pccs-admin-tool:latest \
  python3 /opt/app-root/src/confidential-computing.tee.dcap/tools/PCCSAdminTool/pccs_admin_tool.py \
    -url "https://${NODE_IP}:30081" \
    -in /collateral/platform_collaterals.json \
    -token your-admin-token \
    --no-pccs-cert-check
```

## Disconnected / Air-Gapped Deployment

For disconnected environments, mirror the PCCS image to your local registry and
set the image repository accordingly:

```yaml
image:
  repository: registry.disconnected.local/intel-tdx/pccs
  pullPolicy: IfNotPresent
```

The QGS (Quote Generation Service) running on OpenShift nodes connects to PCCS
via the ClusterIP service at `https://pccs.intel-pccs.svc:8081`. Configure the
QGS PCCS URL to point to this address.
