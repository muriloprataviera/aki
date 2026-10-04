#!/bin/bash
# Creates "Aki Dev", a self-signed code-signing identity in the login keychain,
# once. macOS ties permissions (Screen Recording) to an app's signature: ad-hoc
# signing changes it on every build and the permission would be asked again each
# time; a stable identity keeps it. Local only, never used to ship.
set -euo pipefail
name="Aki Dev"
if security find-certificate -c "$name" >/dev/null 2>&1; then
  echo "\"$name\" already exists"; exit 0
fi
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cat > "$work/cert.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $name
[ext]
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
basicConstraints = critical, CA:false
CNF
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$work/cert.cnf" \
  -keyout "$work/key.pem" -out "$work/cert.pem" 2>/dev/null
openssl pkcs12 -export -legacy -inkey "$work/key.pem" -in "$work/cert.pem" -name "$name" \
  -passout pass:aki -out "$work/aki.p12" 2>/dev/null
security import "$work/aki.p12" -k ~/Library/Keychains/login.keychain-db -P aki -T /usr/bin/codesign >/dev/null
echo "created \"$name\""
