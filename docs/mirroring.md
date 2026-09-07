# Content to Mirror for Disconnected Environments

This page lists the container images and artifacts that must be transferred
across the air gap for Intel TDX remote attestation infrastructure.

## Container Images

Four container images are built on the internet-connected side. Only two need
to cross the air gap.

| Image | Stays on connected side | Crosses air gap | Purpose |
|-------|:-----------------------:|:---------------:|---------|
| `pcs-base` | Build dependency only | No | Base image with Intel DCAP repo |
| `pcs-client-tool` | Yes | No | Merges CSVs, fetches collateral from Intel PCS |
| `pccs` | No | **Yes** | PCCS caching service (OFFLINE mode) |
| `pccs-admin-tool` | No | **Yes** | Inserts collateral into PCCS |

## Building and Exporting Images

On the internet-connected RHEL server:

```bash
cd intel-tdx-remote-attestation-disconnected
./build.sh
```

This builds all four images and exports tarballs into `./images/`:

```
images/
  pcs-client-tool.tar
  pccs-admin-tool.tar
  pccs.tar
```

## What to Transfer

Transfer the following to the disconnected enclave via sneakernet (USB drive,
write-once media, or data diode):

| Artifact | Size (approx) | Frequency | Purpose |
|----------|--------------|-----------|---------|
| `images/pccs.tar` | ~300 MB | Once (or on image update) | PCCS container |
| `images/pccs-admin-tool.tar` | ~200 MB | Once (or on image update) | Admin tool container |
| `platform_collaterals.json` | ~500 KB | Every ~30 days | PCK certs + quote verification collateral |

The `pcs-client-tool.tar` stays on the connected side — it is never needed in
the disconnected enclave.

## Loading Images on the Disconnected Side

On the disconnected RHEL server or a host with access to the enclave registry:

```bash
podman load -i /media/sneakernet/pccs.tar
podman load -i /media/sneakernet/pccs-admin-tool.tar
```

### Pushing to an OpenShift Internal Registry

If deploying PCCS on OpenShift, tag and push the images:

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

If using a separate mirror registry, substitute that hostname and ensure the
cluster has a pull secret configured for it.

## Collateral Refresh

The `platform_collaterals.json` file contains a `nextUpdate` field set to
~30 days from download. After expiration, TDX quote verification fails.

To refresh:

1. On the connected side, re-run `fetch` (no need to re-collect CSVs)
2. Transfer the new `platform_collaterals.json` across the air gap
3. Re-run the Admin Tool `insert` on the disconnected side

Container image tarballs only need to be re-transferred when the images are
rebuilt (e.g., for security patches or upstream updates).
