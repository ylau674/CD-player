// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CDKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "CDKit", targets: ["CDKit"]),
        .executable(name: "AudioCheck", targets: ["AudioCheck"]),
        .executable(name: "HDCDCheck", targets: ["HDCDCheck"]),
        .executable(name: "OpticalCheck", targets: ["OpticalCheck"])
    ],
    targets: [
        .target(name: "HDCD", path: "Sources/HDCD", publicHeadersPath: "include"),
        .executableTarget(name: "HDCDCheck", dependencies: ["HDCD"]),
        .target(
            name: "CDAudioCore",
            dependencies: ["HDCD"],
            linkerSettings: [
                .linkedFramework("AudioToolbox"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("CoreFoundation")
            ]
        ),
        .target(name: "CDKit", dependencies: ["CDAudioCore"]),
        .executableTarget(name: "AudioCheck", dependencies: ["CDKit", "CDAudioCore"]),
        .executableTarget(name: "OpticalCheck", dependencies: ["CDKit"]),
        .target(
            name: "CDAudioCoreTestSupport",
            dependencies: ["CDAudioCore"],
            path: "Tests/CDAudioCoreTestSupport"
        ),
        .testTarget(name: "CDKitTests", dependencies: ["CDKit", "CDAudioCore", "CDAudioCoreTestSupport"]),
        .testTarget(name: "AudioCheckTests", dependencies: ["AudioCheck"])
    ],
    cLanguageStandard: .c11
)
