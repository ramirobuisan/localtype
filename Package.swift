// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "LocalType",
    platforms: [.macOS(.v14)],
    targets: [
        // Prebuilt llama.cpp (Metal-enabled), embedded into the .app by build.sh
        .binaryTarget(name: "llama", path: "Vendor/build-apple/llama.xcframework"),
        .executableTarget(
            name: "LocalType",
            dependencies: ["llama"],
            path: "Sources/LocalType",
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
    ]
)
