#!/bin/bash
# Creates a self-signed "Familiar Dev" code-signing identity in your login keychain.
# scripts/build.sh uses it automatically, so macOS permission grants survive rebuilds.
# Run once. You may get a password dialog when the certificate is trusted.
set -euo pipefail
if security find-identity -v -p codesigning | grep -q "Familiar Dev"; then
  echo "Familiar Dev identity already exists"; exit 0
fi
TMP="$(mktemp -d)"
openssl req -x509 -newkey rsa:2048 -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -days 3650 -nodes \
  -subj "/CN=Familiar Dev" -addext "keyUsage=digitalSignature" -addext "extendedKeyUsage=codeSigning" -addext "basicConstraints=CA:FALSE"
openssl pkcs12 -export -out "$TMP/sk.p12" -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -passout pass:familiar -name "Familiar Dev"
security import "$TMP/sk.p12" -k ~/Library/Keychains/login.keychain-db -P familiar -T /usr/bin/codesign -T /usr/bin/security
security add-trusted-cert -r trustRoot -p codeSign -k ~/Library/Keychains/login.keychain-db "$TMP/cert.pem"
rm -rf "$TMP"
security find-identity -v -p codesigning | grep "Familiar Dev" && echo "done: rebuild with ./scripts/build.sh"
