// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "osaurus-maps",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "osaurus-maps", type: .dynamic, targets: ["osaurus_maps"])
    ],
    targets: [
        .target(
            name: "osaurus_maps",
            path: "Sources/osaurus_maps"
        )
    ]
)