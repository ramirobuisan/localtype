// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Cotypist",
    platforms: [.macOS(.v13)],
    targets: [
        // Prebuilt llama.cpp (Metal-enabled), embedded into the .app by build.sh
        .binaryTarget(name: "llama", path: "Vendor/build-apple/llama.xcframework"),
        .executableTarget(
            name: "Cotypist",
            dependencies: ["llama"],
            path: "Sources/Cotypist",
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
    ]
)
