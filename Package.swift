// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "YeelightBar",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "YeelightKit", targets: ["YeelightKit"]),
        .executable(name: "yeectl", targets: ["yeectl"]),
        .executable(name: "YeelightBarApp", targets: ["YeelightBarApp"]),
    ],
    targets: [
        .target(name: "YeelightKit"),
        .executableTarget(name: "yeectl", dependencies: ["YeelightKit"]),
        .executableTarget(
            name: "YeelightBarApp",
            dependencies: ["YeelightKit"],
            linkerSettings: [.linkedFramework("ScreenCaptureKit")]
        ),
    ]
)
