// swift-tools-version: 6.2
// legibility:description: A Swift 6 client library for the Model Context Protocol (MCP), enabling Swift applications to connect to MCP servers over HTTP/SSE, WebSocket, or stdio.
import PackageDescription

var targets: [Target] = [
    .target(
        name: "MCPClient",
        dependencies: [
            .product(name: "SwiftOAuthClient", package: "SwiftOAuth"),
            .product(name: "SwiftOAuthCore", package: "SwiftOAuth"),
            .product(name: "AsyncHTTPClient", package: "async-http-client"),
            .product(name: "WebSocketKit", package: "websocket-kit"),
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
        // OAuth for MCP servers that require it. An MCP client is pointed at a server by a
        // user and has no pre-registered credentials, so it needs discovery and dynamic
        // registration rather than a token someone pasted in.
        .package(url: "https://github.com/jpurnell/SwiftOAuth", from: "0.3.0"),
        .package(url: "https://github.com/swift-server/async-http-client.git", from: "1.24.0"),
        .package(url: "https://github.com/vapor/websocket-kit.git", from: "2.15.0"),
        .package(url: "https://github.com/swiftlang/swift-docc-plugin", from: "1.4.3"),
    ],
    targets: targets
)
