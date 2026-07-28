// swift-tools-version: 5.9
import PackageDescription
import Foundation

// Absolute path to the package root — used to feed the linker/rpath the
// location of the vendored sherpa-onnx dylibs. Package.swift is evaluated at
// manifest-load time, so #filePath resolves to a stable absolute path.
let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let sherpaLibDir = "\(packageRoot)/Vendor/sherpa-onnx/lib"

let package = Package(
    name: "Onyx",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "RecorderCore", targets: ["RecorderCore"]),
        .executable(name: "Onyx", targets: ["Onyx"]),
        .executable(name: "DiarizerSmoke", targets: ["DiarizerSmoke"]),
        .executable(name: "E2ETrigger", targets: ["E2ETrigger"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "6.29.0"),
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "0.9.0"),
        .package(url: "https://github.com/sparkle-project/Sparkle.git", from: "2.6.0"),
    ],
    targets: [
        .target(
            name: "CSherpaOnnx",
            path: "Sources/CSherpaOnnx",
            sources: ["shim.c"],
            publicHeadersPath: "include",
            linkerSettings: [
                .unsafeFlags([
                    "-L", sherpaLibDir,
                    "-Xlinker", "-rpath", "-Xlinker", sherpaLibDir,
                ]),
                .linkedLibrary("sherpa-onnx-c-api"),
                .linkedLibrary("onnxruntime"),
            ]
        ),
        .target(
            name: "RecorderCore",
            dependencies: [
                "CSherpaOnnx",
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "WhisperKit", package: "WhisperKit"),
            ]
        ),
        .executableTarget(
            name: "Onyx",
            dependencies: [
                "RecorderCore",
                .product(name: "Sparkle", package: "Sparkle"),
            ]
        ),
        .executableTarget(
            name: "DiarizerSmoke",
            dependencies: ["RecorderCore"]
        ),
        .executableTarget(
            name: "E2ETrigger",
            dependencies: ["RecorderCore"]
        ),
        .testTarget(name: "RecorderCoreTests", dependencies: ["RecorderCore"]),
    ]
)
