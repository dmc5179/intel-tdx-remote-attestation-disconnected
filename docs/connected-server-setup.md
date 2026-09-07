# Internet-Connected RHEL Server Setup

This page covers setting up the internet-connected RHEL 9 server that builds
container images and fetches attestation collateral from Intel PCS.

## Prerequisites

- RHEL 9.x with internet access
- `root` or `sudo` access
- Access to a container registry (e.g., `quay.io`) or willingness to transfer
  image tarballs via sneakernet

## Install Packages

```bash
sudo dnf install -y podman skopeo jq openssl python3 git
```

No other packages are required — all Intel tooling runs inside containers.

## Clone the Repository

```bash
git clone https://github.com/dmc5179/openshift-coco-disconnected.git
cd openshift-coco-disconnected/intel-tdx-remote-attestation-disconnected
```

## Build Container Images

```bash
./build.sh
```

This builds four container images:

| Image | Purpose |
|-------|---------|
| `pcs-base` | Base layer (build dependency only, not run directly) |
| `pcs-client-tool` | Merges platform CSVs, fetches collateral from Intel PCS |
| `pccs` | PCCS caching service in OFFLINE mode |
| `pccs-admin-tool` | Inserts collateral into PCCS |

Tarballs are exported to `./images/` for sneakernet transfer.

## Register for an Intel PCS API Key

A free API key is required to fetch collateral from the Intel Provisioning
Certification Service.

1. Go to [api.portal.trustedservices.intel.com](https://api.portal.trustedservices.intel.com/manage-subscriptions)
2. Sign in or create an Intel account
3. Subscribe to the "Intel PCS" API
4. Copy either the primary or secondary subscription key

Store the key securely — you will need it each time you fetch or refresh
collateral.

## PCCS Token Configuration

The PCCS uses SHA-512 hashed tokens for API authentication. The Helm chart
ships with defaults:

| Token | Plaintext default | Purpose |
|-------|------------------|---------|
| Admin | `my-admin-token` | Required to insert collateral via the Admin Tool |
| User | `my-user-token` | Required for client queries to PCCS |

To generate custom token hashes:

```bash
echo -n 'your-admin-token' | sha512sum | awk '{print $1}'
echo -n 'your-user-token' | sha512sum | awk '{print $1}'
```

Keep the plaintext tokens — the PCS Client Tool and Admin Tool prompt for them
at runtime.

## Optional: Run PCCS Locally for Testing

For single-server testing (no physical air gap), you can run PCCS on the same
host as the PCS Client Tool. See
[Disconnected Server Setup](disconnected-server-setup.md) for PCCS deployment
instructions — the steps are identical, just executed on the same machine.

## Directory Structure After Setup

```
intel-tdx-remote-attestation-disconnected/
├── build.sh                      # Build script
├── images/                       # Exported container tarballs
│   ├── pcs-client-tool.tar
│   ├── pccs.tar
│   └── pccs-admin-tool.tar
├── scripts/
│   └── fetch-platform-collateral.sh   # Automated collateral workflow
├── chart/pccs/                   # Helm chart for OpenShift deployment
└── collateral-output/            # Created by fetch script
    ├── platform_list.json        # Merged platform data
    └── platform_collaterals.json # Fetched collateral
```

## Next Steps

1. [Collect platform data](../DEPLOYMENT-GUIDE.md#step-2-collect-platform-data-disconnected-enclave)
   from each TDX host (done on the disconnected side)
2. [Fetch collateral from Intel PCS](connected-pcs-api.md) using your API key
3. Transfer artifacts to the disconnected side (see [Mirroring](mirroring.md))
