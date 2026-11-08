// swift-tools-version: 6.0
import PackageDescription

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
            ]
        )
    ]
)
