// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "WireGuardKit",
    platforms: [
        .macOS(.v12),
        .iOS(.v15),
        .tvOS(.v17)
    ],
    products: [
        .library(name: "WireGuardKit", targets: ["WireGuardKit"])
    ],
    dependencies: [],
    targets: [
        .target(
            name: "WireGuardKit",
            dependencies: ["WireGuardKitGo", "WireGuardKitC"],
            linkerSettings: [
                .unsafeFlags(["-L\(Context.packageDirectory)/Sources/WireGuardKitGo"]),
                .linkedLibrary("wg-go")
            ]
        ),
        .target(
            name: "WireGuardKitC",
            dependencies: [],
            publicHeadersPath: "."
        ),
        .target(
            name: "WireGuardKitGo",
            dependencies: [],
            publicHeadersPath: "."
        )
    ]
)
