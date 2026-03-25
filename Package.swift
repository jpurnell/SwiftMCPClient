// swift-tools-version: 6.0
import PackageDescription

var targets: [Target] = [
    .target(
        name: "MCPClient",
        dependencies: [],
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
    targets: targets
)
