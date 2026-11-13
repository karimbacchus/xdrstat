// swift-tools-version: 6.0
import Foundation
import PackageDescription

// SwiftPM hands the SDK to clang's linker driver as `--sysroot`, which clang doesn't read an SDK version
// from; it then stamps the binary's SDK version with the deployment target instead. macOS decides from
// that stamp whether an app gets the current system design (an old stamp means compatibility mode, with
// no Liquid Glass), so pass the SDK as `-isysroot` as well, which makes clang record the real version.
// scripts/build-app.sh verifies the result.
let sdkRoot = Context.environment["SDKROOT"] ?? [
    "/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk",
    "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk",
].first { FileManager.default.fileExists(atPath: $0) }
let sdkStamp: [LinkerSetting] = sdkRoot.map { [.unsafeFlags(["-Xclang-linker", "-isysroot", "-Xclang-linker", $0])] } ?? []

let package = Package(
    name: "XDRStat",
    platforms: [.macOS("27.0")],
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
