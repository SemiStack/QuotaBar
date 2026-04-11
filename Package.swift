// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "QuotaBar",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "QuotaBar"
        ),
        .testTarget(
            name: "QuotaBarTests",
            dependencies: ["QuotaBar"]
        )
    ]
)
