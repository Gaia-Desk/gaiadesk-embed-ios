// swift-tools-version:5.9
//
// GaiaDeskEmbed for iOS: GaiaDesk support inside your iPhone and iPad app.
//
// The Swift API (MIT) wraps libgaiadesk_embed, which ships as a prebuilt
// static XCFramework (device arm64, simulator arm64 + x86_64; GaiaDesk Native
// Binary Licence, LICENSE-BINARY), downloaded by SwiftPM from this
// repository's release and checked against the checksum below. To build
// against a local copy (`scripts/fetch-binary.sh`, or your own GaiaDesk build
// of the library) put it at Frameworks/GaiaDeskEmbedFFI.xcframework and set
// GAIADESK_EMBED_LOCAL_BINARY=1.

import PackageDescription

// Set by scripts/set-binary.sh <version> <checksum> (scripts/release.sh runs it).
let binaryVersion = "0.1.0"
let binaryChecksum = "60cf374a25eaeaa8cb5afdcb0be01cc929364597d250dbf428d908e4109cd683"

let ffi: Target = Context.environment["GAIADESK_EMBED_LOCAL_BINARY"] != nil
    ? .binaryTarget(name: "GaiaDeskEmbedFFI", path: "Frameworks/GaiaDeskEmbedFFI.xcframework")
    : .binaryTarget(
        name: "GaiaDeskEmbedFFI",
        url: "https://github.com/Gaia-Desk/gaiadesk-embed-ios/releases/download/v\(binaryVersion)/GaiaDeskEmbedFFI.xcframework.zip",
        checksum: binaryChecksum
    )

// What the static library itself links (VideoToolbox H.264; the TLS and
// WebRTC stack need nothing beyond the system's C library).
let systemFrameworks: [LinkerSetting] = [
    "AVFoundation", "CoreFoundation", "CoreMedia", "CoreVideo", "Foundation", "ReplayKit", "Security",
    "SystemConfiguration", "UIKit", "VideoToolbox",
].map { .linkedFramework($0) } + [.linkedLibrary("c++"), .linkedLibrary("resolv")]

let package = Package(
    name: "GaiaDeskEmbed",
    platforms: [.iOS("15.0")],
    products: [
        .library(name: "GaiaDeskEmbed", targets: ["GaiaDeskEmbed"]),
    ],
    targets: [
        ffi,
        .target(
            name: "GaiaDeskEmbed",
            dependencies: ["GaiaDeskEmbedFFI"],
            linkerSettings: systemFrameworks
        ),
        .testTarget(name: "GaiaDeskEmbedTests", dependencies: ["GaiaDeskEmbed"]),
    ]
)
