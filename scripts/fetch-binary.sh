#!/usr/bin/env bash
# Fetch the prebuilt libgaiadesk_embed iOS XCFramework for a release into
# Frameworks/ (where Package.swift's local binary target and the podspec look),
# verifying the SwiftPM checksum published with it.
#
# Usage: scripts/fetch-binary.sh <version>     e.g. scripts/fetch-binary.sh 0.1.0
set -euo pipefail

VERSION="${1:?usage: scripts/fetch-binary.sh <version>}"
BASE="https://github.com/Gaia-Desk/gaiadesk-embed-ios/releases/download/v$VERSION"
DIR="$(cd "$(dirname "$0")/.." && pwd)/Frameworks"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

curl -fsSL "$BASE/GaiaDeskEmbedFFI.xcframework.zip" -o "$TMP/xcf.zip"
curl -fsSL "$BASE/GaiaDeskEmbedFFI.xcframework.zip.checksum" -o "$TMP/checksum"
want="$(tr -d '[:space:]' < "$TMP/checksum")"
got="$(swift package compute-checksum "$TMP/xcf.zip")"
if [ "$want" != "$got" ]; then
  echo "checksum mismatch: expected $want, got $got" >&2
  exit 1
fi
mkdir -p "$DIR"
rm -rf "$DIR/GaiaDeskEmbedFFI.xcframework"
ditto -x -k "$TMP/xcf.zip" "$DIR"
echo "GaiaDeskEmbedFFI.xcframework $VERSION -> $DIR"
