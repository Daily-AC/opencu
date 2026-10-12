// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "OpenCU",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "opencu-engine", targets: ["OpenCU"])],
    targets: [.executableTarget(name: "OpenCU", linkerSettings: [
        .linkedFramework("AppKit"), .linkedFramework("ApplicationServices"),
        .linkedFramework("ScreenCaptureKit"), .linkedFramework("ImageIO"),
        .linkedFramework("Carbon"),
    ])]
)
