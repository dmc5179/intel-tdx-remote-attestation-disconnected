# Intel TDX Remote Attestation Infrastructure for Disconnected Environments

This repo provides containerized tooling for Intel TDX remote attestation in air-gapped (disconnected) environments using the PCCS-based indirect registration flow.

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

## Building

```bash
./build.sh
```

Builds all container images and exports tarballs to `./images/` for sneakernet transfer to the disconnected enclave.
