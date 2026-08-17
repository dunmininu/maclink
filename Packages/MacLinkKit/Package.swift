// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MacLinkKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "MacLinkKit", targets: ["MacLinkKit"])
    ],
    targets: [
        .target(
            name: "MacLinkKit",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "MacLinkKitTests",
            dependencies: ["MacLinkKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
