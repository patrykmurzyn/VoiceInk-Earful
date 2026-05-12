#!/bin/bash
set -euo pipefail

CERT_NAME="VoiceInk Local Dev"
KEYCHAIN_PATH="$HOME/Library/Keychains/login.keychain-db"
APP_PATH="${1:-$HOME/Downloads/VoiceInk.app}"

if security find-identity -v -p codesigning "$KEYCHAIN_PATH" 2>/dev/null | grep -q "$CERT_NAME"; then
  echo "[sign-local] Cert '$CERT_NAME' already in keychain"
else
  echo "[sign-local] Creating self-signed cert '$CERT_NAME'..."
  TMPDIR=$(mktemp -d)
  trap "rm -rf '$TMPDIR'" EXIT

  openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout "$TMPDIR/sign.key" -out "$TMPDIR/sign.crt" \
    -subj "/CN=$CERT_NAME/O=VoiceInk Local Build" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=codeSigning" \
    -addext "basicConstraints=critical,CA:FALSE" 2>&1 | tail -1

  cp "$TMPDIR/sign.crt" /tmp/voiceink-sign.crt

  P12_PASS="voiceink"
  openssl pkcs12 -export -legacy \
    -inkey "$TMPDIR/sign.key" -in "$TMPDIR/sign.crt" \
    -name "$CERT_NAME" -passout "pass:$P12_PASS" -out "$TMPDIR/sign.p12"

  security import "$TMPDIR/sign.p12" -k "$KEYCHAIN_PATH" \
    -T /usr/bin/codesign -T /usr/bin/security -A -P "$P12_PASS"

  security add-trusted-cert -p codeSign -k "$KEYCHAIN_PATH" "$TMPDIR/sign.crt"
  echo "[sign-local] Cert installed and trusted for code signing"
fi

if [ ! -d "$APP_PATH" ]; then
  echo "[sign-local] ERROR: App not found at $APP_PATH"
  exit 1
fi

echo "[sign-local] Signing $APP_PATH..."
codesign --force --deep --sign "$CERT_NAME" "$APP_PATH"

echo "[sign-local] Verification:"
codesign -dvv "$APP_PATH" 2>&1 | grep -E "Identifier|Authority|TeamIdentifier|Signature" || true
echo "[sign-local] Done."
