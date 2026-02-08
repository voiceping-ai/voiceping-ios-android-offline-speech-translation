// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SherpaOnnxKit",
    platforms: [.iOS(.v17)],
    products: [
        .library(name: "SherpaOnnxKit", targets: ["SherpaOnnxKit"]),
    ],
    targets: [
        .target(
            name: "SherpaOnnxKit",
            dependencies: ["sherpa_onnx", "onnxruntime"],
            path: "Sources/SherpaOnnxKit",
            linkerSettings: [.linkedLibrary("c++")]
        ),
        .binaryTarget(
            name: "sherpa_onnx",
            path: "sherpa-onnx.xcframework"
        ),
        .binaryTarget(
            name: "onnxruntime",
            path: "onnxruntime.xcframework"
        ),
    ]
)
