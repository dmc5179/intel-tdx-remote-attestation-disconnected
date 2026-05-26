# Intel TDX Remote Attestation Infrastructure for disconnected environments

- This repo is based on the intel docs below and is designed to support Confidential Compute and Containers for disconnected environments

https://cc-enabling.trustedservices.intel.com/intel-tdx-enabling-guide/02/infrastructure_setup/#intel-tdx-remote-attestation


Based on this doc: https://cc-enabling.trustedservices.intel.com/intel-tdx-enabling-guide/02/infrastructure_setup/#on-offline-manual-multi-platform-pccs-based-indirect-registration
https://cc-enabling.trustedservices.intel.com/intel-tdx-enabling-guide/02/infrastructure_setup/#on-offline-manual-multi-platform-local-cache-based-indirect-registration

## A subscription key for the Intel PCS

## The PCK Cert ID Retrieval Tool (PCKCIDRT) 

— A tool to support the retrieval of the PM and other platform information.

For Linux version:
- Install prebuilt Intel(R) SGX SDK , you can download it from [download.01.org](https://download.01.org/intel-sgx/latest/linux-latest/distro/)
    a. sgx_linux_x64_sdk_${version}.bin

## The PCCS Admin Tool  NOT NEEDED????

— A tool to facilitate manual retrieval of platform information from PCCS (if PCK Cert ID Retrieval Tool inserted it there) and insertion of registration collateral into PCCS.

## The PCS Client Tool

— A tool to facilitate registration collateral parsing and manual REST API communication with Intel® SGX and Intel® TDX Provisioning Certification Service for flows where PCCS is not present (or does not have a direct Internet connectivity). The tool provides helper functionality for Indirect Registration, PCK Certificate retrieval, and verification collateral retrieval especially in multi-platform environments.

- clone the tool in a connected environment and pull the modules
```
git clone https://github.com/intel/confidential-computing.tee.dcap.git
cd confidential-computing.tee.dcap/tools/PcsClientTool/
python3 -m pip download -r requirements.txt -d ./offline_modules
```

- Move the entire git repo over and install the modules from the directory copied
```
pip install --no-index --find-links=/path/to/local/dir -r requirements.txt
```

