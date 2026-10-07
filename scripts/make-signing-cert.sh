#!/usr/bin/env bash
# One-time setup: makes "HomeClerk Local", a self-signed code-signing certificate, in your login
# keychain. build.sh signs with it when it's there, so every build has the same signature and macOS
# keeps HomeClerk's permissions (Reminders, notifications, folders) across updates instead of asking
# again. It only matters on this Mac: other Macs don't trust it, so it isn't a Developer ID.
#
# Usage:  scripts/make-signing-cert.sh
# Remove: Keychain Access ▸ login ▸ My Certificates ▸ delete "HomeClerk Local" (builds go back to ad hoc)

set -euo pipefail

NAME="HomeClerk Local"
KEYCHAIN="${KEYCHAIN:-$HOME/Library/Keychains/login.keychain-db}"
OPENSSL=/usr/bin/openssl   # macOS's own (LibreSSL): its .p12 files import cleanly with `security`

if security find-identity -p codesigning "$KEYCHAIN" 2>/dev/null | grep -q "\"$NAME\""; then
    echo "\"$NAME\" is already in your keychain — nothing to do."
    exit 0
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
cd "$WORK"

cat > cert.cnf <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CNF

# Ten years, so it doesn't expire out from under the builds
"$OPENSSL" req -x509 -newkey rsa:2048 -nodes -days 3650 -config cert.cnf -keyout key.pem -out cert.pem 2>/dev/null
# The .p12's password only carries the key into the keychain; it's random and discarded with the folder
PASSWORD=$("$OPENSSL" rand -hex 16)
"$OPENSSL" pkcs12 -export -inkey key.pem -in cert.pem -name "$NAME" -out cert.p12 -passout "pass:$PASSWORD"
# -T lets codesign use the key without asking each build
security import cert.p12 -k "$KEYCHAIN" -P "$PASSWORD" -T /usr/bin/codesign >/dev/null

echo "Made \"$NAME\". The next ./build.sh signs with it."
echo "If macOS asks whether codesign may use the key, click Always Allow."
