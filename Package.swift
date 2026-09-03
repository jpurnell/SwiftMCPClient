// swift-tools-version: 6.2
// legibility:description: A Swift 6 client library for the Model Context Protocol (MCP), enabling Swift applications to connect to MCP servers over HTTP/SSE, WebSocket, or stdio.
import PackageDescription

var targets: [Target] = [
    .target(
        name: "MCPClient",
        dependencies: [
            .product(name: "SwiftOAuthClient", package: "swift-oauth"),
            .product(name: "MCP", package: "swift-mcp-sdk"),
            .product(name: "Crypto", package: "swift-crypto"),
            .product(name: "SwiftOAuthCore", package: "swift-oauth"),
            .product(name: "AsyncHTTPClient", package: "async-http-client"),
            .product(name: "NIOCore", package: "swift-nio"),
            .product(name: "NIOPosix", package: "swift-nio"),
            .product(name: "NIOHTTP1", package: "swift-nio"),
            .product(name: "WebSocketKit", package: "websocket-kit"),
        ],
        // Declared rather than left implicit. SwiftPM does not claim this catalog on a
        // plain build and warns that it is unhandled; the obvious quietening — `exclude` —
        // silently drops all eight hand-written guides from the generated documentation,
        // leaving symbol pages only. Verified by generating both ways and looking for them.
        resources: [
            .copy("MCPClient.docc")
        ],
        swiftSettings: [
            .swiftLanguageMode(.v6)
        ]
    ),
    .testTarget(
        name: "MCPClientTests",
        dependencies: [
            "MCPClient",
            // The transports' authorization behaviour is wire behaviour: which header a
            // request actually carried, and what happened after the server refused one.
            // Asserting that needs a server, so the tests stand one up on loopback.
            .product(name: "NIOCore", package: "swift-nio"),
            .product(name: "NIOPosix", package: "swift-nio"),
            .product(name: "NIOHTTP1", package: "swift-nio"),
        ]
    ),
]

#if os(macOS)
targets.append(
    .executableTarget(
        name: "MCPExplorer",
        dependencies: [
            "MCPClient",
            .product(name: "SwiftOAuthClient", package: "swift-oauth"),
            .product(name: "SwiftOAuthCore", package: "swift-oauth")
        ],
        swiftSettings: [
            .swiftLanguageMode(.v6)
        ]
    )
)
// The Explorer's own logic — what it remembers between launches, and how it decides
// whether to restore a session — is testable without a window on screen.
targets.append(
    .testTarget(
        name: "MCPExplorerTests",
        dependencies: ["MCPExplorer"],
        swiftSettings: [
            .swiftLanguageMode(.v6)
        ]
    )
)
// Survey utility, not a product: connects with the persisted OAuth session and dumps
// the server's tool catalog as JSON. MCPExplorer's tool list is a browsing surface;
// auditing 69 tool schemas needs them in a file.
targets.append(
    .executableTarget(
        name: "MCPDump",
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
        //
        // `swift-oauth`, not `SwiftOAuth`. SwiftPM takes a package's identity from the last
        // path component of its URL, so the two repositories are two packages holding one
        // library — and a dependency graph reaching both fails to resolve. This is the public
        // export, and it is the one SwiftMCPServer resolves.
        .package(url: "https://github.com/jpurnell/swift-oauth", from: "0.11.1"),
        // The protocol surface, shared with SwiftMCPServer rather than written twice. The
        // wire types are where duplication costs most: every specification revision would
        // otherwise be implemented once here and once there, and the two would drift in ways
        // only a live server would reveal.
        //
        // Pinned exactly. Tracking a branch would let a build change because the SDK moved.
        //
        // `swift-mcp-sdk`, not `swift-sdk` — the same identity problem as above. Both are
        // public and both carry this tag, so the choice is not about access: it is that a
        // package can only be one of them, and anything depending on this client and on
        // SwiftMCPServer together must agree on which.
        .package(url: "https://github.com/jpurnell/swift-mcp-sdk", exact: "2026.7.28"),
        .package(url: "https://github.com/swift-server/async-http-client.git", from: "1.24.0"),
        // Already present transitively via websocket-kit; declared because the OAuth loopback
        // listener uses it directly.
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
        .package(url: "https://github.com/vapor/websocket-kit.git", from: "2.15.0"),
        .package(url: "https://github.com/swiftlang/swift-docc-plugin", from: "1.4.3"),
    ],
    targets: targets
)
