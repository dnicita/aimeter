#!/bin/bash
# Create a STABLE self-signed code-signing identity ("ClaudeUsageBar Local") in
# the login keychain. Run this ONCE. After this, build-local.sh signs every build
# with the same identity, so the code signature (Designated Requirement) never
# changes — and macOS stops re-prompting for Keychain access and Accessibility
# permission on every rebuild.
#
# Safe to re-run: if the identity already exists, it does nothing.
set -euo pipefail
cd "$(dirname "$0")"

IDENTITY="ClaudeUsageBar Local"
KC="$HOME/Library/Keychains/login.keychain-db"

if security find-certificate -c "$IDENTITY" "$KC" >/dev/null 2>&1; then
    echo "✅ Signing identity '$IDENTITY' already present — nothing to do."
    exit 0
fi

echo "🔐 Creating self-signed code-signing identity '$IDENTITY'…"
TMP=$(mktemp -d)
cat > "$TMP/cert.cnf" <<'EOF'
[req]
distinguished_name = dn
x509_extensions = v3
prompt = no
[dn]
CN = ClaudeUsageBar Local
[v3]
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
basicConstraints = critical, CA:false
EOF

openssl req -x509 -newkey rsa:2048 -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
    -days 3650 -nodes -config "$TMP/cert.cnf" 2>/dev/null

# Legacy PKCS#12 (SHA1/3DES) — required for Apple's Security.framework to import.
openssl pkcs12 -export -legacy -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
    -out "$TMP/id.p12" -passout pass:cubpass -name "$IDENTITY" \
    -macalg sha1 -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES 2>/dev/null

# Import; -T allows codesign to use the private key non-interactively.
security import "$TMP/id.p12" -k "$KC" -P "cubpass" -T /usr/bin/codesign -A
rm -rf "$TMP"

echo "✅ Done. First build after this will prompt once for Keychain access to the"
echo "   private key — choose 'Always Allow'. Then signing is fully non-interactive."
