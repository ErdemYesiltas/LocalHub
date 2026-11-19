// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LocalHub",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "LocalHubApp", targets: ["LocalHubApp"]),
        .executable(name: "localhub", targets: ["localhub"]),
        .library(name: "LocalHubCore", targets: ["LocalHubCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/vapor/vapor.git", from: "4.110.0"),
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", exact: "0.12.1"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.37.0"),
        .package(url: "https://github.com/ajevans99/swift-json-schema", exact: "0.13.2"),
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
        .package(path: "../clients/swift"),
    ],
    targets: [
        .target(name: "LocalHubCore", dependencies: [
            .product(name: "Vapor", package: "vapor"),
            .product(name: "MCP", package: "swift-sdk"),
            .product(name: "NIOSSL", package: "swift-nio-ssl"),
            .product(name: "JSONSchema", package: "swift-json-schema"),
            .product(name: "GRDB", package: "GRDB.swift"),
        ]),
        .executableTarget(name: "LocalHubApp", dependencies: ["LocalHubCore", .product(name: "LocalHubClient", package: "swift")]),
        .executableTarget(name: "localhub", dependencies: ["LocalHubCore"]),
        .testTarget(name: "LocalHubCoreTests", dependencies: [
            "LocalHubCore",
            .product(name: "XCTVapor", package: "vapor"),
            .product(name: "GRDB", package: "GRDB.swift"),
            .product(name: "LocalHubClient", package: "swift"),
        ]),
        .testTarget(name: "LocalHubAppTests", dependencies: [
            "LocalHubApp", "LocalHubCore",
            .product(name: "Vapor", package: "vapor"),
        ]),
    ]
)
