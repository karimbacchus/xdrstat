// swift-tools-version: 6.0
import Foundation
import PackageDescription

// SwiftPM hands the SDK to clang's linker driver as `--sysroot`, which clang doesn't read an SDK version
// from; it then stamps the binary with the deployment target instead (LC_BUILD_VERSION "sdk 15.0").
// macOS decides from that stamp whether an app gets the current system design, so a binary stamped 15.0
// runs in compatibility mode with no Liquid Glass. Passing the SDK as `-isysroot` as well makes clang
// record the real version. scripts/build-app.sh verifies the result.
let sdkRoot = Context.environment["SDKROOT"] ?? [
    "/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk",
    "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk",
].first { FileManager.default.fileExists(atPath: $0) }
let sdkStamp: [LinkerSetting] = sdkRoot.map { [.unsafeFlags(["-Xclang-linker", "-isysroot", "-Xclang-linker", $0])] } ?? []

let package = Package(
    name: "XDRStat",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "XDRStat",
            path: "Sources/XDRStat",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("CoreWLAN"),
                .linkedFramework("CoreLocation"),
                .linkedFramework("SystemConfiguration"),
                .linkedLibrary("IOReport"),
            ] + sdkStamp
        )
    ]
)
