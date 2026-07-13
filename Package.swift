// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "TokenScope",
    platforms: [.macOS(.v14)],
    targets: [
        .systemLibrary(
            name: "CSQLite",
            path: "Sources/CSQLite"
        ),
        .executableTarget(
            name: "TokenScope",
            dependencies: ["CSQLite"],
            path: "Sources/TokenScope"
        )
    ]
)
