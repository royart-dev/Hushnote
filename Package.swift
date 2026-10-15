// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Hushnote",
    platforms: [.macOS("14.2")],
    products: [
        .executable(name: "Hushnote", targets: ["Hushnote"]),
        .executable(name: "HushnoteWorker", targets: ["HushnoteWorker"])
    ],
    dependencies: [.package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.17.7")],
    targets: [
        .target(name: "CaptureRing", publicHeadersPath: "include"),
        .target(name: "HushnoteCore"),
        .executableTarget(name: "Hushnote", dependencies: ["HushnoteCore", "CaptureRing"]),
        .executableTarget(name: "HushnoteWorker", dependencies: ["HushnoteCore", .product(name: "FluidAudio", package: "FluidAudio")]),
        .executableTarget(name: "HushnoteChecks", dependencies: ["HushnoteCore", "CaptureRing"], path: "Tests/HushnoteCoreTests")
    ],
    swiftLanguageModes: [.v5]
)
