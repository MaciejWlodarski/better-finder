// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "BetterFinder",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "BetterFinder", targets: ["BetterFinder"])
    ],
    targets: [
        .executableTarget(
            name: "BetterFinder",
            path: "Sources/BetterFinder",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("QuickLookUI"),
                .linkedFramework("QuickLookThumbnailing"),
                .linkedFramework("CoreServices"),
                .linkedFramework("UniformTypeIdentifiers")
            ]
        )
    ]
)
