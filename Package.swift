// swift-tools-version: 6.0
import PackageDescription

var targets: [Target] = [
    .target(
        name: "MCPClient",
        dependencies: [
            .product(name: "AsyncHTTPClient", package: "async-http-client"),
        ],
        swiftSettings: [
            .swiftLanguageMode(.v6)
        ]
    ),
    .testTarget(
        name: "MCPClientTests",
        dependencies: ["MCPClient"]
    ),
]

#if os(macOS)
targets.append(
    .executableTarget(
        name: "MCPExplorer",
        dependencies: ["MCPClient"],
        swiftSettings: [
            .swiftLanguageMode(.v6)
        ]
    )
)
#endif

let package = Package(
    name: "SwiftMCPClient",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
        .tvOS(.v17),
        .watchOS(.v10)
    ],
    products: [
        .library(name: "MCPClient", targets: ["MCPClient"]),
    ],
    dependencies: [
        .package(url: "https://github.com/swift-server/async-http-client.git", from: "1.24.0"),
    ],
    targets: targets
)
