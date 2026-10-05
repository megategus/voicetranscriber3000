// swift-tools-version: 6.0
import PackageDescription

// TranscriptCore and AssistantKit are plain Swift and also build on Linux,
// so their tests can run in CI containers. CaptureKit and SessionKit need
// Apple media frameworks and WhisperKit, so they only exist on macOS.

var products: [Product] = [
    .library(name: "TranscriptCore", targets: ["TranscriptCore"]),
    .library(name: "AssistantKit", targets: ["AssistantKit"]),
]

var dependencies: [Package.Dependency] = []

var targets: [Target] = [
    .target(name: "TranscriptCore"),
    .target(name: "AssistantKit", dependencies: ["TranscriptCore"]),
    .testTarget(name: "TranscriptCoreTests", dependencies: ["TranscriptCore"]),
    .testTarget(
        name: "AssistantKitTests",
        dependencies: ["AssistantKit"],
        resources: [.copy("Fixtures")]
    ),
]

#if os(macOS)
products += [
    .library(name: "CaptureKit", targets: ["CaptureKit"]),
    .library(name: "SessionKit", targets: ["SessionKit"]),
]
dependencies += [
    .package(url: "https://github.com/argmaxinc/WhisperKit", from: "1.1.0"),
]
targets += [
    .target(
        name: "CaptureKit",
        dependencies: [
            "TranscriptCore",
            .product(name: "WhisperKit", package: "WhisperKit"),
        ]
    ),
    .target(name: "SessionKit", dependencies: ["TranscriptCore", "AssistantKit", "CaptureKit"]),
    .testTarget(
        name: "CaptureKitTests",
        dependencies: ["CaptureKit"],
        resources: [.copy("Fixtures")]
    ),
    .testTarget(name: "SessionKitTests", dependencies: ["SessionKit"]),
]
#endif

let package = Package(
    name: "Kit",
    platforms: [.macOS(.v14)],
    products: products,
    dependencies: dependencies,
    targets: targets
)
