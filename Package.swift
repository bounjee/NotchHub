// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "NotchHub",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "NotchHub",
            linkerSettings: [.linkedFramework("ServiceManagement")]
        ),
        .executableTarget(name: "notch-hook"),
        .testTarget(name: "NotchHubTests", dependencies: ["NotchHub", "notch-hook"]),
    ],
    swiftLanguageModes: [.v6]
)
