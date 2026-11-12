// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "QuotaKit", platforms: [.iOS(.v17), .macOS(.v14)], products: [.library(name: "QuotaKit", targets: ["QuotaKit"])], targets: [.target(name: "QuotaKit"), .testTarget(name: "QuotaKitTests", dependencies: ["QuotaKit"])])
