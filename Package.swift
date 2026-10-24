// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "kids-quota",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "KidsQuotaCore", targets: ["KidsQuotaCore"]),
        .library(name: "KidsQuotaService", targets: ["KidsQuotaService"]),
        .executable(name: "kids-quota-service", targets: ["QuotaDaemon"]),
        .executable(name: "kids-quota-agent", targets: ["QuotaAgent"]),
        .executable(name: "kids-quota-bridge", targets: ["QuotaBridge"])
    ],
    targets: [
        .systemLibrary(name: "CSQLite"),
        .target(name: "KidsQuotaCore", dependencies: ["CSQLite"], resources: [.copy("Resources/public_suffix_list.dat")]),
        .target(name: "KidsQuotaService", dependencies: ["KidsQuotaCore"]),
        .executableTarget(name: "QuotaDaemon", dependencies: ["KidsQuotaService"]),
        .executableTarget(name: "QuotaAgent", dependencies: ["KidsQuotaService"]),
        .executableTarget(name: "QuotaBridge", dependencies: ["KidsQuotaService"]),
        .testTarget(name: "KidsQuotaCoreTests", dependencies: ["KidsQuotaCore"]),
        .testTarget(name: "KidsQuotaServiceTests", dependencies: ["KidsQuotaService"])
    ]
)
