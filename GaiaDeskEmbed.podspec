# CocoaPods spec for GaiaDeskEmbed (iOS): the same Swift sources as the Swift
# package plus the prebuilt XCFramework. React Native
# (@gaiadesk/embed-react-native) and Flutter (gaiadesk_embed) depend on it.
#
# The XCFramework is not in git: `scripts/fetch-binary.sh <version>` puts a
# release's in Frameworks/ (the release zip of this repository contains it
# too, which is what `source` points at).
Pod::Spec.new do |s|
  s.name = "GaiaDeskEmbed"
  s.version = "0.1.0"
  s.summary = "A \"Get help\" button for iOS apps: share the app's own screen with your support team."
  s.description = "GaiaDesk embed for iOS: consent first, an always-visible sharing indicator, masked views painted out before encoding, view-only by default with an opt-in guided mode delivered inside the app."
  s.homepage = "https://github.com/Gaia-Desk/gaiadesk-embed-ios"
  s.license = { :type => "MIT (sources); GaiaDesk Native Binary Licence (GaiaDeskEmbedFFI.xcframework)", :file => "LICENSE" }
  s.author = { "GaiaDesk" => "noreply@gaiadesk.net" }
  s.platform = :ios, "15.0"
  s.swift_version = "5.9"
  s.source = { :http => "https://github.com/Gaia-Desk/gaiadesk-embed-ios/releases/download/v#{s.version}/GaiaDeskEmbed-#{s.version}.zip" }
  s.source_files = "Sources/GaiaDeskEmbed/**/*.swift"
  s.vendored_frameworks = "Frameworks/GaiaDeskEmbedFFI.xcframework"
  s.frameworks = "AVFoundation", "CoreFoundation", "CoreMedia", "CoreVideo", "Foundation", "ReplayKit", "Security", "SystemConfiguration", "UIKit", "VideoToolbox"
  s.libraries = "c++", "resolv"
end
