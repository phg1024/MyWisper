// swift-tools-version: 6.0
import Foundation
import PackageDescription

// sherpa-onnx's C API and onnxruntime come from the Python wheel in ../venv; build.sh copies them into Vendor/.
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let vendorLib = "\(root)/Vendor/sherpa-onnx/lib"

let package = Package(
    name: "MyWisper",
    platforms: [.macOS(.v15)],
    targets: [
        .systemLibrary(name: "CSherpaOnnx", path: "Sources/CSherpaOnnx"),
        .executableTarget(
            name: "MyWisper",
            dependencies: ["CSherpaOnnx"],
            path: "Sources/MyWisper",
            linkerSettings: [
                .unsafeFlags([
                    "-L\(vendorLib)",
                    "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks",
                    "-Xlinker", "-rpath", "-Xlinker", vendorLib,
                ]),
            ]
        ),
    ],
    swiftLanguageModes: [.v5]
)
