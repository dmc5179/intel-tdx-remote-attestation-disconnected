# Intel TDX Remote Attestation Infrastructure for Disconnected Environments

Containerized tooling for Intel TDX remote attestation in air-gapped
(disconnected) environments using the PCCS-based indirect registration flow.

## Parent Repository

This is a sub-repo of
[openshift-coco-disconnected](../README.md), which covers the full CoCo
deployment stack (operators, mirroring, AutoShift policies, and this
attestation infrastructure).

## Architecture

```
  INTERNET-CONNECTED SIDE                    DISCONNECTED ENCLAVE
 ========================                   ======================

 PCS Client Tool (container)                 TDX Host A, B, ... N
   merge .csv files ◄──── sneakernet ◄──── PCKIDRetrievalTool (RPM)
   fetch collateral from Intel PCS
         │
         │ platform_collaterals.json         PCCS (container, OFFLINE)
         │ + container image tarballs          serves collateral on :8081
         └──── sneakernet ──────────────►      ◄── Admin Tool inserts
                                               ◄── KBS queries for
                                                   TDX quote verification
```

## Documentation

| Guide | Description |
|-------|-------------|
| [Connected Server Setup](docs/connected-server-setup.md) | Internet-connected RHEL server: packages, building images, API key |
| [Disconnected Server Setup](docs/disconnected-server-setup.md) | Disconnected RHEL server: PCCS deployment (Podman or Helm), TLS, tokens |
| [Connecting to Intel PCS API](docs/connected-pcs-api.md) | Collecting platform CSVs, fetching collateral from Intel PCS |
| [PCCS to OpenShift Connectivity](docs/disconnected-pccs-openshift.md) | Firewall, KBS QCNL config, NodePort/Route, troubleshooting |
| [Content to Mirror](docs/mirroring.md) | Container images and artifacts to transfer across the air gap |
| [Full Deployment Guide](DEPLOYMENT-GUIDE.md) | End-to-end step-by-step (all details in one page) |
| [Helm Chart](chart/pccs/README.md) | PCCS Helm chart for OpenShift |
| [Operational Scripts](scripts/README.md) | Automated collateral workflow script |

## Containers

| Image | Containerfile | Purpose | Runs On |
|-------|--------------|---------|---------|
| `pcs-base` | `PCS-Base-Containerfile` | Base image with Intel DCAP repo | Build dependency only |
| `pcs-client-tool` | `PCS-Client-Tool-Containerfile` | Merges platform CSVs, fetches collateral from Intel PCS | Internet-connected side |
| `pccs-admin-tool` | `PCCS-Admin-Tool-Containerfile` | Inserts collateral into PCCS | Disconnected enclave |
| `pccs` | `PCCS-Containerfile` | PCCS caching service (OFFLINE mode) | Disconnected enclave |

The PCK Cert ID Retrieval Tool (PCKCIDRT) runs on bare metal — see the
[Full Deployment Guide](DEPLOYMENT-GUIDE.md) for the rationale.

## Quick Start

```bash
# 1. Build container images (internet-connected side)
./build.sh

# 2. Collect CSV files from TDX hosts
./scripts/fetch-platform-collateral.sh collect ./csv-dir/

# 3. Fetch collateral from Intel PCS
./scripts/fetch-platform-collateral.sh fetch --api-key YOUR_KEY

# 4. Transfer images + collateral to disconnected side, then insert into PCCS
./scripts/fetch-platform-collateral.sh insert https://pccs-host:8081 \
  --admin-token my-admin-token
```

See the [docs/](docs/) directory for detailed guides on each step.

## Intel PCS Subscription Key

A free API key is required to fetch collateral. Register at
[api.portal.trustedservices.intel.com](https://api.portal.trustedservices.intel.com/manage-subscriptions).

## FIPS Considerations

PCCS is a Node.js application. Node.js is **not FIPS-validated** by Red Hat.
In a FIPS-enabled environment, deploy PCCS on a host outside the FIPS
enforcement boundary or document the exception. TLS certificates must use
FIPS-approved algorithms (RSA-2048+ or ECDSA P-256/P-384).

## OpenShift CoreOS and PCKCIDRT

On OpenShift bare-metal nodes running CoreOS, `sgx-pck-id-retrieval-tool`
cannot be installed via `dnf`. Options:

1. **Pre-install before cluster deployment** — run PCKCIDRT during host
   provisioning, before CoreOS is laid down (recommended).
2. **Boot from RHEL live media** — temporarily boot from RHEL, install and
   run PCKCIDRT, then reboot into CoreOS.
3. **Privileged debug pod** — `oc debug node/<node>` with `chroot /host`.
   UEFI variable access may be unreliable.

## Building

```bash
./build.sh
```

Builds all container images and exports tarballs to `./images/` for sneakernet
transfer.
