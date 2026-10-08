#!/usr/bin/env bash
# Prepare a release of GaiaDeskEmbed (iOS) from a release build of the
# XCFramework (GaiaDesk's scripts/build-embed-ios.sh → embed/out/ios/):
#
#   1. checks the zip: its SwiftPM checksum matches the .checksum beside it,
#      it holds the ios-arm64 and simulator slices, no build machine path and
#      no test-source marker;
#   2. scripts/set-binary.sh <version> <checksum> (Package.swift + podspec version);
#   3. unpacks the XCFramework into Frameworks/ (pod lib lint, local builds);
#   4. dist/: the release assets
#        GaiaDeskEmbedFFI.xcframework.zip + .checksum   (SwiftPM, scripts/fetch-binary.sh)
#        GaiaDeskEmbed-<version>.zip + .sha256          (the CocoaPod's http source:
#                                                        Sources/, Frameworks/, LICENSE*, README)
#      and writes the pod zip's SHA-256 into the podspec's source.
#
# Publishes nothing: it prints the commands (commit, tag, GitHub release,
# `pod trunk push`). Usage:
#   scripts/release.sh <version> <path/to/GaiaDeskEmbedFFI.xcframework.zip>
set -euo pipefail

VERSION="${1:?usage: scripts/release.sh <version> <GaiaDeskEmbedFFI.xcframework.zip>}"
ZIP="${2:?usage: scripts/release.sh <version> <GaiaDeskEmbedFFI.xcframework.zip>}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST="$ROOT/dist"
NAME=GaiaDeskEmbedFFI.xcframework
fail() { echo "release.sh: $*" >&2; exit 1; }

[ -f "$ZIP" ] || fail "no such file: $ZIP"
[ -f "$ZIP.checksum" ] || fail "no $ZIP.checksum beside it (build-embed-ios.sh writes one)"
grep -q "^## $VERSION\$" "$ROOT/CHANGELOG.md" || fail "CHANGELOG.md has no '## $VERSION' section"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
ZIP="$(cd "$(dirname "$ZIP")" && pwd)/$(basename "$ZIP")"
# Outside any package directory (in one, `swift package` loads its manifest first).
CHECKSUM="$(cd "$TMP" && swift package compute-checksum "$ZIP")"
[ "$CHECKSUM" = "$(tr -d '[:space:]' < "$ZIP.checksum")" ] || fail "checksum of $ZIP does not match $ZIP.checksum"
ditto -x -k "$ZIP" "$TMP/x"
XCF="$TMP/x/$NAME"
[ -d "$XCF" ] || fail "the zip has no top-level $NAME"
PLIST="$XCF/Info.plist"
ids="$(plutil -extract AvailableLibraries json -o - "$PLIST" | /usr/bin/python3 -c 'import json,sys; print(" ".join(sorted(l["LibraryIdentifier"] for l in json.load(sys.stdin))))')"
case " $ids " in *" ios-arm64 "*) ;; *) fail "no ios-arm64 (device) slice: $ids" ;; esac
case "$ids" in *ios-arm64_x86_64-simulator*) ;; *) fail "no ios-arm64_x86_64-simulator slice (a --sim-only build?): $ids" ;; esac
while IFS= read -r lib; do
  if strings -a "$lib" | grep "NOT-FOR-RELEASE" >/dev/null; then fail "$lib is a test-source build"; fi
  if strings -a "$lib" | grep -F "$HOME" >/dev/null; then fail "$lib carries $HOME (a --debug build?)"; fi
done < <(find "$XCF" -name '*.a')
[ -f "$XCF/LICENSE-BINARY" ] || fail "the XCFramework carries no LICENSE-BINARY"

bash "$ROOT/scripts/set-binary.sh" "$VERSION" "$CHECKSUM"

mkdir -p "$ROOT/Frameworks"
rm -rf "$ROOT/Frameworks/$NAME"
ditto "$XCF" "$ROOT/Frameworks/$NAME"

rm -rf "$DIST" && mkdir -p "$DIST"
cp "$ZIP" "$DIST/$NAME.zip"
echo "$CHECKSUM" > "$DIST/$NAME.zip.checksum"

# The pod's source: no top-level folder, no podspec (it carries this zip's hash).
POD="$TMP/pod"
mkdir -p "$POD/Frameworks"
ditto "$ROOT/Sources" "$POD/Sources"
ditto "$XCF" "$POD/Frameworks/$NAME"
cp "$ROOT/LICENSE" "$ROOT/LICENSE-BINARY" "$ROOT/README.md" "$ROOT/CHANGELOG.md" "$POD/"
(cd "$POD" && zip -qry -X "$DIST/GaiaDeskEmbed-$VERSION.zip" .)
POD_SHA="$(shasum -a 256 "$DIST/GaiaDeskEmbed-$VERSION.zip" | awk '{print $1}')"
echo "$POD_SHA  GaiaDeskEmbed-$VERSION.zip" > "$DIST/GaiaDeskEmbed-$VERSION.zip.sha256"
sed -i '' -E "s/(:sha256 => \")[^\"]*(\")/\1$POD_SHA\2/" "$ROOT/GaiaDeskEmbed.podspec"
grep -q ":sha256 => \"$POD_SHA\"" "$ROOT/GaiaDeskEmbed.podspec" || fail "could not write the pod zip's sha256 into the podspec"

echo
ls -l "$DIST"
cat <<NEXT

Ready. Next (needs: gh auth with write access to Gaia-Desk/gaiadesk-embed-ios; a CocoaPods trunk session):
  pod lib lint GaiaDeskEmbed.podspec --allow-warnings     # local sources + Frameworks/
  git add Package.swift GaiaDeskEmbed.podspec && git commit -m "GaiaDeskEmbed $VERSION"
  git tag v$VERSION && git push origin main v$VERSION
  gh release create v$VERSION --repo Gaia-Desk/gaiadesk-embed-ios --title "GaiaDeskEmbed $VERSION" \\
    --notes-file <(awk '/^## $VERSION\$/{f=1;next} /^## /{f=0} f' CHANGELOG.md) dist/*
  # then: CI green on the tag (SwiftPM downloads the release's zip), and
  pod spec lint GaiaDeskEmbed.podspec --allow-warnings    # downloads the release's pod zip
  pod trunk push GaiaDeskEmbed.podspec --allow-warnings
NEXT
