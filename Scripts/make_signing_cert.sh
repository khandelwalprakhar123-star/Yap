#!/bin/bash
# One-time setup: creates a self-signed "LocalFlow Dev" code-signing identity
# in the login keychain so LocalFlow.app keeps the same identity (and its
# macOS permission grants) across rebuilds.
set -euo pipefail

if security find-identity -v -p codesigning 2>/dev/null | grep -q "LocalFlow Dev"; then
    echo "✓ 'LocalFlow Dev' identity already exists"
    exit 0
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

openssl req -newkey rsa:2048 -nodes -keyout "$TMP/key.pem" \
    -x509 -days 3650 -subj "/CN=LocalFlow Dev" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=critical,codeSigning" \
    -addext "basicConstraints=critical,CA:false" \
    -out "$TMP/cert.pem"
openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
    -name "LocalFlow Dev" -out "$TMP/lf.p12" -passout pass:localflow

security import "$TMP/lf.p12" -k ~/Library/Keychains/login.keychain-db \
    -P localflow -T /usr/bin/codesign
# Trust it for code signing (may show a confirmation dialog once).
security add-trusted-cert -p codeSign \
    -k ~/Library/Keychains/login.keychain-db "$TMP/cert.pem" || true

security find-identity -v -p codesigning | grep "LocalFlow Dev" \
    && echo "✓ Identity created" \
    || { echo "✗ Identity not usable — check Keychain Access"; exit 1; }
