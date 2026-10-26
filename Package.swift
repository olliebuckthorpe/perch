// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Perch",
    platforms: [.macOS(.v14)],
    targets: [
        // Apple's on-device model (macOS 26) is optional: weak-linked so Perch still runs without it.
        .executableTarget(name: "Perch", path: "Sources/Perch",
                          linkerSettings: [.unsafeFlags(["-Xlinker", "-weak_framework", "-Xlinker", "FoundationModels"])])
    ]
)
