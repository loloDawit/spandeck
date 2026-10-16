// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Headroom",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Headroom",
            path: "Sources/Headroom",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("ServiceManagement"),
            ]
        ),
        .testTarget(
            name: "HeadroomTests",
            dependencies: ["Headroom"],
            path: "Tests/HeadroomTests",
            resources: [.copy("Fixtures")]
        ),
    ]
)
