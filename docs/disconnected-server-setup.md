# Disconnected RHEL Server and PCCS Setup

This page covers setting up the disconnected (air-gapped) RHEL 9 server and
deploying PCCS to serve attestation collateral to TDX hosts and OpenShift.

## Prerequisites

- RHEL 9.x with no internet access (enclave network only)
- `root` or `sudo` access
- Container image tarballs transferred via sneakernet (see [Mirroring](mirroring.md))
- `platform_collaterals.json` transferred from the connected side

## Install Packages

```bash
sudo dnf install -y podman jq openssl
```

If `dnf` repos are not available in the enclave, pre-stage the RPMs or use a
local repository mirror.

## Load Container Images

```bash
podman load -i /media/sneakernet/pccs.tar
podman load -i /media/sneakernet/pccs-admin-tool.tar
```

Verify the images loaded:

```bash
podman images | grep -E 'pccs|admin'
```

## Deploy PCCS with Podman

### Generate TLS Certificates

PCCS requires TLS. Generate a self-signed certificate:

```bash
mkdir -p ./pccs-ssl-key
openssl req -x509 -newkey rsa:4096 \
  -keyout ./pccs-ssl-key/private.pem -out ./pccs-ssl-key/file.crt \
  -days 3650 -nodes -subj "/CN=PCCS"
chmod 644 ./pccs-ssl-key/private.pem
```

The private key needs `644` permissions so the non-root container user (UID
1001) can read it. In production, use certificates from your PKI.

### Start PCCS

```bash
podman volume create pccs-data

podman run -d \
  --name pccs \
  --network host \
  -v pccs-data:/opt/intel/sgx-dcap-pccs/data:Z \
  -v ./pccs-ssl-key:/opt/intel/sgx-dcap-pccs/ssl_key:Z \
  quay.io/danclark/intel-tdx/pccs:latest
```

`--network host` is required instead of `-p 8081:8081` because rootless Podman
port mapping only binds to localhost. Host networking makes PCCS reachable from
other machines on the enclave network.

### Verify PCCS is Running

```bash
podman logs pccs
# Should show: "HTTPS Server is running on: https://localhost:8081"

curl -sk https://127.0.0.1:8081/sgx/certification/v4/rootcacrl
# Expected: 404 "No cache data" (empty cache before collateral insert)
```

### Insert Collateral

Using the automated script:

```bash
./scripts/fetch-platform-collateral.sh insert https://127.0.0.1:8081 \
  --admin-token my-admin-token
```

Or manually with the Admin Tool container:

```bash
printf '%s\nn\n' "my-admin-token" | podman run --rm -i \
  -v ./platform_collaterals.json:/data/platform_collaterals.json:Z \
  --network host \
  -w /opt/app-root/src/confidential-computing.tee.dcap.pccs/PccsAdminTool \
  quay.io/danclark/intel-tdx/pccs-admin-tool:latest \
  python3 pccsadmin.py put --no-pccs-cert-check \
    -u https://127.0.0.1:8081/sgx/certification/v4/platformcollateral \
    -i /data/platform_collaterals.json
```

The default admin token is `my-admin-token` (baked into the Helm chart
`values.yaml`). Change it for production.

### Verify Collateral Was Loaded

```bash
curl -sk https://127.0.0.1:8081/sgx/certification/v4/rootcacrl
# Should return a hex-encoded CRL (not 404)
```

## Deploy PCCS on OpenShift (Alternative)

For OpenShift deployments, use the Helm chart instead of Podman:

```bash
helm install pccs ./chart/pccs/ \
  --namespace intel-pccs --create-namespace
```

Default tokens are baked into `values.yaml`:
- Admin: `my-admin-token`
- User: `my-user-token`

PCCS is available at:
- **ClusterIP:** `https://pccs.intel-pccs.svc:8081`
- **NodePort:** `https://<node-ip>:30081`

See the [Helm chart README](../chart/pccs/README.md) for full configuration
options.

## PCCS Configuration Reference

| Setting | Default | Description |
|---------|---------|-------------|
| HTTPS Port | 8081 | Listen port |
| Caching Mode | OFFLINE | No outbound connections; collateral inserted manually |
| Admin Token | `my-admin-token` | For inserting collateral |
| User Token | `my-user-token` | For client queries |
| TLS | Self-signed | Generated at deploy time |
| Database | SQLite | Persistent volume at `/opt/intel/sgx-dcap-pccs/data` |

## FIPS Considerations

The PCCS container automatically detects FIPS mode at startup via
`/proc/sys/crypto/fips_enabled` and enables `OPENSSL_FIPS_MODE` when running
on a FIPS-enabled host. No manual configuration is required.

Node.js in the Red Hat UBI image dynamically links against the system OpenSSL
(`libssl.so.3`, `libcrypto.so.3`), and all algorithms used are FIPS-approved.
However, Node.js itself is **not FIPS-validated** by Red Hat — if your security
policy requires FIPS-validated crypto for all services, document the exception.

TLS certificates must use FIPS-approved algorithms (RSA-2048+ or ECDSA
P-256/P-384). The default self-signed cert uses RSA-4096 with SHA-256. Avoid
SHA-1.

## Next Steps

1. [Configure OpenShift connectivity](disconnected-pccs-openshift.md) so TDX
   hosts and the KBS can reach PCCS
2. Set up collateral refresh (every ~30 days) — see [Mirroring](mirroring.md)
