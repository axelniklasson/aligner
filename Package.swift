// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Aligner",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Aligner",
            path: "Sources/Aligner",
            linkerSettings: [.linkedFramework("Carbon")]
        )
    ]
)
