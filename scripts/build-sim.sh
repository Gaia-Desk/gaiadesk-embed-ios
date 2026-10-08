#!/usr/bin/env bash
# Build the examples (and, with --test, the XCTest suite inside a host app)
# for the iOS Simulator WITHOUT xcodebuild, and optionally run the tests.
#
# Why: Xcode 26 refuses every iOS destination until its iOS 26 platform is
# downloaded (~8 GB): "iOS 26.5 is not installed". The SDK ships with Xcode,
# so swiftc can still build simulator apps, and an older simulator runtime
# (iOS 18.x) runs them (deployment target 15.0). With the platform installed,
# prefer Xcode / `xcodebuild test -scheme GaiaDeskEmbed`.
#
#   scripts/build-sim.sh                     # build/sim/HelpDeskUIKit.app, HelpDeskSwiftUI.app
#   scripts/build-sim.sh --test [<udid>]     # + build/sim/GaiaDeskEmbedTests.app, run it on <udid>
#                                            #   (default: the first available iPhone), exit status = the tests'
#
# Needs Frameworks/GaiaDeskEmbedFFI.xcframework with an ios-arm64-simulator
# slice (scripts/fetch-binary.sh, or GaiaDesk's scripts/build-embed-ios.sh).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/build/sim"
MIN=15.0
T="arm64-apple-ios$MIN-simulator"
SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"
PLAT="$(xcrun --sdk iphonesimulator --show-sdk-platform-path)"
XCF="$ROOT/Frameworks/GaiaDeskEmbedFFI.xcframework"
SLICE="$(ls -d "$XCF"/ios-*simulator 2>/dev/null | head -1)"
[ -n "$SLICE" ] || { echo "no simulator slice in $XCF" >&2; exit 1; }
SWIFTC=(xcrun --sdk iphonesimulator swiftc -target "$T" -sdk "$SDK" -swift-version 5 -Onone -gnone)
FRAMEWORKS=(-framework AVFoundation -framework CoreFoundation -framework CoreMedia -framework CoreVideo -framework Foundation -framework ReplayKit
  -framework Security -framework SystemConfiguration -framework UIKit -framework VideoToolbox -framework SwiftUI -framework CoreImage -lc++ -lresolv)

rm -rf "$OUT" && mkdir -p "$OUT/mod" "$OUT/obj"
TESTING=()
[ "${1:-}" = --test ] && TESTING=(-enable-testing)
# 1. The package's module, as a static library.
"${SWIFTC[@]}" -parse-as-library -emit-library -static -emit-module -module-name GaiaDeskEmbed ${TESTING[@]+"${TESTING[@]}"} \
  -emit-module-path "$OUT/mod/GaiaDeskEmbed.swiftmodule" -I "$SLICE/Headers" \
  "$ROOT"/Sources/GaiaDeskEmbed/*.swift -o "$OUT/obj/libGaiaDeskEmbed.a"

plist() { # $1 = app dir, $2 = executable, $3 = bundle id, $4 = name, $5 = url scheme (or "")
  cat > "$1/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>$2</string>
  <key>CFBundleIdentifier</key><string>$3</string>
  <key>CFBundleName</key><string>$2</string>
  <key>CFBundleDisplayName</key><string>$4</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>MinimumOSVersion</key><string>$MIN</string>
  <key>CFBundleSupportedPlatforms</key><array><string>iPhoneSimulator</string></array>
  <key>UIDeviceFamily</key><array><integer>1</integer><integer>2</integer></array>
  <key>UILaunchScreen</key><dict/>
  <key>UIRequiresFullScreen</key><true/>
  $( [ -n "$5" ] && echo "<key>CFBundleURLTypes</key><array><dict><key>CFBundleURLSchemes</key><array><string>$5</string></array></dict></array>" )
</dict></plist>
EOF
}

app() { # $1 = name, $2 = bundle id, $3 = display, $4 = scheme, $5.. = sources and extra flags
  local name="$1" id="$2" disp="$3" scheme="$4"
  shift 4
  local dir="$OUT/$name.app"
  mkdir -p "$dir"
  "${SWIFTC[@]}" -I "$OUT/mod" -I "$SLICE/Headers" "$@" -L "$OUT/obj" -lGaiaDeskEmbed \
    "$SLICE/libgaiadesk_embed.a" "${FRAMEWORKS[@]}" -Xlinker -dead_strip -o "$dir/$name"
  plist "$dir" "$name" "$id" "$disp" "$scheme"
  codesign --force --sign - --timestamp=none "$dir" >/dev/null
  echo "built $dir"
}

app HelpDeskUIKit net.gaiadesk.examples.helpdesk.uikit "Acme Bank (UIKit)" helpdeskuikit -parse-as-library "$ROOT"/Examples/HelpDeskUIKit/Sources/*.swift
app HelpDeskSwiftUI net.gaiadesk.examples.helpdesk.swiftui "Acme Bank (SwiftUI)" helpdeskswiftui -parse-as-library "$ROOT"/Examples/HelpDeskSwiftUI/Sources/*.swift

[ "${1:-}" = --test ] || exit 0

# 2. The tests in a host app (XCTest embedded), run in the simulator.
DIR="$OUT/GaiaDeskEmbedTests.app"
mkdir -p "$DIR/Frameworks"
cp "$ROOT/Tests/TestHost/main.swift" "$OUT/obj/main.swift"
app GaiaDeskEmbedTests net.gaiadesk.embed.tests "GaiaDeskEmbed Tests" "" \
  -F "$PLAT/Developer/Library/Frameworks" -I "$PLAT/Developer/usr/lib" -L "$PLAT/Developer/usr/lib" \
  -framework XCTest -Xlinker -rpath -Xlinker @executable_path/Frameworks \
  "$OUT/obj/main.swift" "$ROOT"/Tests/GaiaDeskEmbedTests/*.swift
# XCTest and everything it loads (public and private test frameworks, its dylibs).
cp -R "$PLAT"/Developer/Library/Frameworks/*.framework "$DIR/Frameworks/"
for f in XCTestCore XCTestSupport XCUnit XCTAutomationSupport; do
  cp -R "$PLAT/Developer/Library/PrivateFrameworks/$f.framework" "$DIR/Frameworks/"
done
cp "$PLAT"/Developer/usr/lib/*.dylib "$DIR/Frameworks/" 2>/dev/null || true
codesign --force --deep --sign - --timestamp=none "$DIR" >/dev/null

UDID="${2:-}"
if [ -z "$UDID" ]; then
  UDID="$(xcrun simctl list devices available | awk -F '[()]' '/iPhone/{print $2; exit}')"
fi
xcrun simctl boot "$UDID" 2>/dev/null || true
xcrun simctl bootstatus "$UDID" -b >/dev/null
xcrun simctl install "$UDID" "$DIR"
LOG="$OUT/tests.log"
xcrun simctl launch --console-pty --terminate-running-process "$UDID" net.gaiadesk.embed.tests > "$LOG" 2>&1 || true
cat "$LOG"
grep -q "GAIADESK-TESTS passed=[0-9]* failed=0" "$LOG"
