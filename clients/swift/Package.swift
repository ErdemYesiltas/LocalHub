// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LocalHubClient",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [.library(name: "LocalHubClient", targets: ["LocalHubClient"])],
    targets: [.target(name: "LocalHubClient")]
)
