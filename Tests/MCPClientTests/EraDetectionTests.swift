import Foundation
import Testing
import MCP
@testable import MCPClient

/// Working out which era of MCP a server speaks, without being told.
///
/// The specification's own procedure: attempt a modern request first, and on `400` **inspect
/// the body before falling back**. Modern servers also answer `400` for an unsupported version,
/// a missing capability, or a header mismatch — so a client that treats every `400` as "this
/// must be an old server" downgrades a modern server that was merely correcting it, and then
/// sends `initialize` to something that removed the method.
@Suite("Era detection")
struct EraDetectionTests {

    /// A modern JSON-RPC error means a modern server. The right response is to act on what it
    /// said, not to conclude it is old.
    @Test("A recognised modern error means the server is modern", arguments: [
        -32020, // HeaderMismatch
        -32021, // MissingRequiredClientCapability
        -32022  // UnsupportedProtocolVersion
    ])
    func modernErrorsMeanModern(code: Int) {
        #expect(MCPClientConnection.era(forRefusalCode: code) == .stateless)
    }

    /// A `400` whose body says nothing a modern server would say is an old server that did not
    /// understand the request. That is the only case where falling back is right.
    @Test("An unrecognised refusal means an earlier era")
    func unrecognisedMeansHandshake() {
        #expect(MCPClientConnection.era(forRefusalCode: nil) == .handshake)
        #expect(MCPClientConnection.era(forRefusalCode: -32600) == .handshake)
        #expect(MCPClientConnection.era(forRefusalCode: -32601) == .handshake)
    }

    /// An implementation-defined error is not evidence either way. Those codes are
    /// grandfathered for SDK use and both eras emit them, so reading one as an era signal would
    /// be reading a coincidence.
    @Test("An implementation-defined error is not an era signal")
    func implementationDefinedIsNotASignal() {
        #expect(MCPClientConnection.era(forRefusalCode: -32000) == .handshake)
    }
}
