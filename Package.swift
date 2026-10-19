// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SurgeGuard",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "surge-guard", targets: ["SurgeGuard"]),
               .executable(name: "surge-gate", targets: ["SurgeGate"])],
    targets: [
        .target(name: "SurgeGuardCore"),
        .executableTarget(name: "SurgeGuard", dependencies: ["SurgeGuardCore"]),
        .executableTarget(name: "SurgeGate", dependencies: ["SurgeGuardCore"]),
        .executableTarget(name: "surge-guard-tests", dependencies: ["SurgeGuardCore"], path: "Tests/SurgeGuardTests")
    ]
)
