#!/bin/bash
# Creates a self-signed code signing identity for NotchHub, once per Mac.
#
# Ad-hoc signatures change with every build, and macOS ties Screen Recording permission to
# the signature, so every update would lose it. Signed with this identity instead, every build
# keeps the same designated requirement and the permission survives updates.
#
# The identity lives in its own keychain file under ~/.notchhub-signing, so the login keychain
# is left alone and nothing is marked as trusted. scripts/build-app.sh uses it when present.
set -euo pipefail

DIR="$HOME/.notchhub-signing"
KEYCHAIN="$DIR/signing.keychain-db"
NAME="NotchHub Self-Signed"
# Only protects this throwaway keychain, which holds nothing but the signing key.
PASSWORD="notchhub-signing"

if [ -f "$DIR/.done" ] && [ -f "$KEYCHAIN" ]; then
    echo "Signing identity already exists in $KEYCHAIN"
    exit 0
fi

mkdir -p "$DIR"
chmod 700 "$DIR"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
# The system's LibreSSL: Homebrew's OpenSSL 3 writes PKCS#12 files the Keychain can't read.
OPENSSL=/usr/bin/openssl

cat > "$WORK/openssl.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
basicConstraints = critical, CA:false
CNF

"$OPENSSL" req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$WORK/openssl.cnf" \
    -keyout "$WORK/key.pem" -out "$WORK/cert.pem" 2>/dev/null
"$OPENSSL" pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" -name "$NAME" \
    -out "$WORK/identity.p12" -passout pass:"$PASSWORD"

security create-keychain -p "$PASSWORD" "$KEYCHAIN"
# A half-made keychain would make the next run think it is done.
trap 'rm -rf "$WORK"; [ -f "$DIR/.done" ] || security delete-keychain "$KEYCHAIN" 2>/dev/null || true' EXIT
security set-keychain-settings "$KEYCHAIN"
security unlock-keychain -p "$PASSWORD" "$KEYCHAIN"
security import "$WORK/identity.p12" -k "$KEYCHAIN" -P "$PASSWORD" -T /usr/bin/codesign >/dev/null
# Let codesign use the key without a prompt.
security set-key-partition-list -S apple-tool:,apple: -s -k "$PASSWORD" "$KEYCHAIN" >/dev/null

touch "$DIR/.done"
echo "Created signing identity \"$NAME\" in $KEYCHAIN"
