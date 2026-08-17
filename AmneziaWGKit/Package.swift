// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "AmneziaWGKit",
    platforms: [
        .macOS(.v12),
        .iOS(.v15),
        .tvOS(.v17)
    ],
    products: [
        .library(name: "AmneziaWGKit", targets: ["AmneziaWGKit"])
    ],
    dependencies: [],
    targets: [
        .target(
            name: "AmneziaWGKit",
            dependencies: ["AmneziaWGKitGo", "AmneziaWGKitC"],
            linkerSettings: [
                .unsafeFlags(["-L\(Context.packageDirectory)/Sources/AmneziaWGKitGo"]),
                .linkedLibrary("awg-go")
            ]
        ),
        .target(
            name: "AmneziaWGKitC",
            dependencies: [],
            publicHeadersPath: "."
        ),
        .target(
            name: "AmneziaWGKitGo",
            dependencies: [],
            publicHeadersPath: "."
        )
    ]
)
