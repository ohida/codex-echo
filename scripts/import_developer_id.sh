#!/bin/bash

set -euo pipefail

die() {
  printf '%s\n' "$1" >&2
  exit 1
}

if [[ "$#" -ne 2 ]]; then
  die "Usage: import_developer_id.sh <certificate-path> <keychain-path>"
fi

: "${CODE_SIGN_IDENTITY:?CODE_SIGN_IDENTITY is required}"
: "${P12_BASE64:?P12_BASE64 is required}"
: "${P12_PASSWORD:?P12_PASSWORD is required}"

certificate="$1"
keychain="$2"

if [[ -e "$certificate" || -e "$keychain" ]]; then
  die "Certificate and keychain destinations must not already exist."
fi

umask 077
keychain_password="$(/usr/bin/uuidgen)"
trap 'unset keychain_password' EXIT

printf '%s' "$P12_BASE64" | /usr/bin/base64 -D > "$certificate"
[[ -s "$certificate" ]] || die "Decoded Developer ID certificate is empty."

openssl_output=""
if ! openssl_output="$(
  P12_PASSWORD="$P12_PASSWORD" /usr/bin/openssl pkcs12 \
    -in "$certificate" \
    -passin env:P12_PASSWORD \
    -noout \
    2>&1
)"
then
  printf '%s\n' "$openssl_output" >&2
  die "Developer ID certificate or password is invalid."
fi
unset openssl_output

/usr/bin/security create-keychain -p "$keychain_password" "$keychain"
/usr/bin/security set-keychain-settings -lut 7200 "$keychain"
/usr/bin/security unlock-keychain -p "$keychain_password" "$keychain"
/usr/bin/security import "$certificate" \
  -k "$keychain" \
  -P "$P12_PASSWORD" \
  -T /usr/bin/codesign \
  -T /usr/bin/security \
  >/dev/null
/usr/bin/security set-key-partition-list \
  -S apple-tool:,apple: \
  -s \
  -k "$keychain_password" \
  "$keychain" \
  >/dev/null
/usr/bin/security list-keychains -d user -s "$keychain"
/usr/bin/security find-identity -v -p codesigning "$keychain" \
  | /usr/bin/grep -F -- "$CODE_SIGN_IDENTITY" \
  >/dev/null
/bin/rm -f -- "$certificate"
