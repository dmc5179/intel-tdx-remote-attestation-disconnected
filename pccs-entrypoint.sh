#!/bin/bash
# Detect host FIPS mode and enable PCCS FIPS support accordingly.
# /proc/sys/crypto/fips_enabled is visible inside the container
# because containers share the host kernel.
if [ "$(cat /proc/sys/crypto/fips_enabled 2>/dev/null)" = "1" ]; then
    echo "FIPS mode detected — enabling OPENSSL_FIPS_MODE"
    export NODE_CONFIG='{"OPENSSL_FIPS_MODE":true}'
fi

exec node pccs_server.js
