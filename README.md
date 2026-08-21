# Intel TDX Remote Attestation Infrastructure for Disconnected Environments

This repo provides containerized tooling for Intel TDX remote attestation in air-gapped (disconnected) environments using the PCCS-based indirect registration flow.

## Parent Repository

This is a sub-repo of [openshift-coco-disconnected](../README.md), which covers
the full CoCo deployment stack (operators, mirroring, AutoShift policies, and
this attestation infrastructure).

## Quick Start

See **[DEPLOYMENT-GUIDE.md](DEPLOYMENT-GUIDE.md)** for the full step-by-step deployment workflow covering:

- Architecture overview (what runs where)
- Why the PCK Cert ID Retrieval Tool cannot be containerized
- Building and exporting container images on the internet-connected side
- Collecting platform data from each TDX host
- Fetching attestation collateral from Intel PCS
- Deploying PCCS and loading collateral in the disconnected enclave
- Collateral refresh (every ~30 days)
- Adding new hosts and TCB recovery

## Reference Docs

- [Intel TDX Remote Attestation Infrastructure Setup](https://cc-enabling.trustedservices.intel.com/intel-tdx-enabling-guide/02/infrastructure_setup/#intel-tdx-remote-attestation)
- [Offline PCCS-Based Indirect Registration](https://cc-enabling.trustedservices.intel.com/intel-tdx-enabling-guide/02/infrastructure_setup/#on-offline-manual-multi-platform-pccs-based-indirect-registration)
- [Offline Local Cache-Based Indirect Registration](https://cc-enabling.trustedservices.intel.com/intel-tdx-enabling-guide/02/infrastructure_setup/#on-offline-manual-multi-platform-local-cache-based-indirect-registration)

## Containers

| Image | Containerfile | Purpose | Runs On |
|-------|--------------|---------|---------|
| `pcs-base` | `PCS-Base-Containerfile` | Base image with Intel DCAP repo cloned | Build dependency only |
| `pcs-client-tool` | `PCS-Client-Tool-Containerfile` | Merges platform CSVs, fetches collateral from Intel PCS | Internet-connected side |
| `pccs-admin-tool` | `PCCS-Admin-Tool-Containerfile` | Inserts collateral into PCCS | Disconnected enclave |
| `pccs` | `PCCS-Containerfile` | PCCS caching service (OFFLINE mode) | Disconnected enclave |

The PCK Cert ID Retrieval Tool (PCKCIDRT) runs on bare metal — see `PCKCIDRT-Containerfile` for the rationale.

## Intel PCS Subscription Key

A subscription key is required to fetch collateral from the Intel Provisioning Certification Service. Register for free at [api.portal.trustedservices.intel.com](https://api.portal.trustedservices.intel.com/manage-subscriptions).

## PCS Client Tool

Sourced from [intel/confidential-computing.tee.dcap](https://github.com/intel/confidential-computing.tee.dcap) (`tools/PcsClientTool/`).

For offline module pre-download (if building in a restricted connected environment):

```bash
git clone https://github.com/intel/confidential-computing.tee.dcap.git
cd confidential-computing.tee.dcap/tools/PcsClientTool/
python3 -m pip download -r requirements.txt -d ./offline_modules
```

Then install from the local directory:

```bash
pip install --no-index --find-links=/path/to/offline_modules -r requirements.txt
```

## FIPS Considerations

PCCS is a Node.js application. Node.js is **not FIPS-validated** by Red Hat.
In a FIPS-enabled cluster, PCCS should run outside the FIPS enforcement boundary
(e.g., on a separate utility host) or the risk should be documented and accepted.
The TLS certificates served by PCCS should use FIPS-approved algorithms
(RSA-2048+ or ECDSA P-256/P-384).

## OpenShift CoreOS and PCKCIDRT

On OpenShift bare-metal nodes running CoreOS, `sgx-pck-id-retrieval-tool`
cannot be installed via `dnf`. Options:

1. **Pre-install before cluster deployment** — run PCKCIDRT during the host
   provisioning phase, before CoreOS is laid down.
2. **Boot from a live RHEL image** — boot the host from RHEL installation media,
   install and run PCKCIDRT, then boot back into CoreOS.
3. **Use a privileged debug pod** — `oc debug node/<node>` with `chroot /host`
   and install the RPM temporarily. This works for SGX device access but UEFI
   variable access may be unreliable depending on kernel/firmware version.

See the [DEPLOYMENT-GUIDE.md](DEPLOYMENT-GUIDE.md) for details on the PCKCIDRT
UEFI write behavior.

## Building

```bash
./build.sh
```

Builds all container images and exports tarballs to `./images/` for sneakernet transfer to the disconnected enclave.
