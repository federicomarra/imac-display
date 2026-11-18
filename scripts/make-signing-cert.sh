#!/bin/bash
# One-time setup: creates the self-signed "iMacDisplay Signing" certificate that
# scripts/make-dmg.sh and the Release workflow sign the apps with. macOS ties
# permissions (Screen Recording, Accessibility…) to the signature: with a stable
# certificate they survive updates, ad-hoc signed builds lose them every time.
#
# Adds the certificate to the login keychain and, if the GitHub CLI is logged
# in, stores it in this repo's secrets SIGNING_P12 and SIGNING_P12_PASSWORD.
set -euo pipefail
cd "$(dirname "$0")/.."
name="iMacDisplay Signing"
if security find-certificate -c "$name" >/dev/null 2>&1; then
  echo "'$name' is already in your keychain." >&2
  exit 1
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
pass=$(/usr/bin/openssl rand -base64 24)
cat > "$tmp/cert.conf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $name
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF
# System LibreSSL on purpose: its .p12 format is the one `security import` reads.
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 7300 -config "$tmp/cert.conf" \
  -keyout "$tmp/key.pem" -out "$tmp/cert.pem" 2>/dev/null
/usr/bin/openssl pkcs12 -export -inkey "$tmp/key.pem" -in "$tmp/cert.pem" -name "$name" \
  -out "$tmp/signing.p12" -passout "pass:$pass"
security import "$tmp/signing.p12" -k login.keychain -P "$pass" -T /usr/bin/codesign
echo "Added '$name' to the login keychain."

if command -v gh >/dev/null && gh auth status >/dev/null 2>&1; then
  base64 -i "$tmp/signing.p12" | gh secret set SIGNING_P12
  printf %s "$pass" | gh secret set SIGNING_P12_PASSWORD
  echo "Stored SIGNING_P12 and SIGNING_P12_PASSWORD in the GitHub repo secrets."
else
  echo "Add these GitHub repo secrets so released builds use the same certificate:"
  echo "SIGNING_P12_PASSWORD: $pass"
  echo "SIGNING_P12:"
  base64 -i "$tmp/signing.p12"
fi
