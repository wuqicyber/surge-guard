// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SurgeGuard",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "surge-guard", targets: ["SurgeGuard"]),
               .executable(name: "surge-gate", targets: ["SurgeGate"]),
               .executable(name: "surge-guard-launch", targets: ["SurgeLaunch"])],
    targets: [
        .systemLibrary(name: "CPcap"),
        .target(name: "SurgeGuardCore", dependencies: ["CPcap"]),
        .executableTarget(name: "SurgeGuard", dependencies: ["SurgeGuardCore"]),
        .executableTarget(name: "SurgeGate", dependencies: ["SurgeGuardCore"]),
        .executableTarget(name: "SurgeLaunch", linkerSettings: [.linkedFramework("Security"), .linkedFramework("SystemConfiguration")]),
        .executableTarget(name: "surge-guard-tests", dependencies: ["SurgeGuardCore"], path: "Tests/SurgeGuardTests")
    ]
)
