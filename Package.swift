// swift-tools-version: 6.0
import Foundation
import PackageDescription

// sherpa-onnx's C API and onnxruntime (dylibs) and llama.cpp (static, with Metal) are in Vendor/:
// ./fetch-deps.sh puts them there.
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let vendorLib = "\(root)/Vendor/sherpa-onnx/lib"
let llamaLib = "\(root)/Vendor/llama/lib"

let package = Package(
    name: "MyWisper",
    platforms: [.macOS(.v15)],
    targets: [
        .systemLibrary(name: "CSherpaOnnx", path: "Sources/CSherpaOnnx"),
        .systemLibrary(name: "CLlama", path: "Sources/CLlama"),
        .executableTarget(
            name: "MyWisper",
            dependencies: ["CSherpaOnnx", "CLlama"],
            path: "Sources/MyWisper",
            linkerSettings: [
                .unsafeFlags([
                    "-L\(vendorLib)",
                    "-L\(llamaLib)",
                    "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks",
                    "-Xlinker", "-rpath", "-Xlinker", vendorLib,
                ]),
                .linkedFramework("Accelerate"),
                .linkedFramework("Foundation"),
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
            ]
        ),
        .testTarget(
            name: "MyWisperTests",
            dependencies: ["MyWisper"],
            path: "Tests/MyWisperTests"
        ),
    ],
    swiftLanguageModes: [.v5]
)
