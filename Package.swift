// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MacPulse",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "MacPulse",
            path: "Sources/MacPulse",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .linkedLibrary("sqlite3"),
                .linkedFramework("IOKit"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("SystemConfiguration"),
            ]
        ),
        .testTarget(name: "MacPulseTests", dependencies: ["MacPulse"], path: "Tests/MacPulseTests"),
    ]
)
