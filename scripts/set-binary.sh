#!/usr/bin/env bash
# Point Package.swift (and the podspec's version) at a release's XCFramework:
# rewrites `binaryVersion` and `binaryChecksum` (the SwiftPM checksum of
# GaiaDeskEmbedFFI.xcframework.zip, `swift package compute-checksum`) and the
# podspec's `s.version`. scripts/release.sh calls it; run it by hand to point
# at an already-published release.
#
# Usage: scripts/set-binary.sh <version> <checksum>
#        scripts/set-binary.sh 0.1.0 dc6e2ee1b47123680003c675b2214807270b131b0be0052de1cccf8fe8c52ff8
set -euo pipefail

VERSION="${1:?usage: scripts/set-binary.sh <version> <checksum>}"
CHECKSUM="${2:?usage: scripts/set-binary.sh <version> <checksum>}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ ]] || { echo "not a version: $VERSION" >&2; exit 2; }
[[ "$CHECKSUM" =~ ^[0-9a-f]{64}$ ]] || { echo "not a SwiftPM checksum (64 lowercase hex): $CHECKSUM" >&2; exit 2; }

PKG="$ROOT/Package.swift"
POD="$ROOT/GaiaDeskEmbed.podspec"
grep -q '^let binaryVersion = "' "$PKG" && grep -q '^let binaryChecksum = "' "$PKG" \
  || { echo "Package.swift has no binaryVersion/binaryChecksum line" >&2; exit 1; }
grep -q '^  s.version = "' "$POD" || { echo "the podspec has no s.version line" >&2; exit 1; }

sed -i '' -E \
  -e "s/^let binaryVersion = \"[^\"]*\"/let binaryVersion = \"$VERSION\"/" \
  -e "s/^let binaryChecksum = \"[^\"]*\"/let binaryChecksum = \"$CHECKSUM\"/" "$PKG"
sed -i '' -E -e "s/^  s.version = \"[^\"]*\"/  s.version = \"$VERSION\"/" "$POD"

grep -q "^let binaryVersion = \"$VERSION\"" "$PKG" && grep -q "^let binaryChecksum = \"$CHECKSUM\"" "$PKG" \
  && grep -q "^  s.version = \"$VERSION\"" "$POD" || { echo "rewrite failed" >&2; exit 1; }
echo "Package.swift: binaryVersion $VERSION, binaryChecksum $CHECKSUM; podspec: version $VERSION"
