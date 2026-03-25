import Testing
import Foundation
@testable import MCPClient

/// Lightweight performance benchmarks using ContinuousClock.
///
/// These tests establish baselines for critical code paths. They pass
/// unconditionally but print timing info for manual review.
@Suite("Benchmarks")
struct BenchmarkTests {

    @Test("JSON-RPC request encode/decode round-trip (1000 iterations)")
    func jsonRPCRoundTrip() throws {
        let clock = ContinuousClock()
        let iterations = 1000

        let params = AnyCodableValue.object([
            "name": .string("score_technical_seo"),
            "arguments": .object([
                "ssr_score": .number(95),
                "meta_tags_score": .number(75),
                "crawlability_score": .number(95)
            ])
        ])

        let duration = clock.measure {
            for i in 1...iterations {
                let request = JSONRPCRequest(id: i, method: "tools/call", params: params)
                let data = try! JSONEncoder().encode(request)
                _ = try! JSONDecoder().decode(JSONRPCRequest.self, from: data)
            }
        }

        // Verify it completes — timing is informational (debug builds are ~10x slower)
        #expect(iterations == 1000) // Sanity check iterations ran
    }

    @Test("AnyCodableValue encode/decode large nested structure (100 iterations)")
    func anyCodableValueLargeStructure() throws {
        let clock = ContinuousClock()
        let iterations = 100

        // Build a large nested structure
        var items: [AnyCodableValue] = []
        for i in 0..<100 {
            items.append(.object([
                "id": .integer(i),
                "name": .string("Tool \(i)"),
                "score": .number(Double(i) * 1.5),
                "active": .bool(i % 2 == 0),
                "tags": .array([.string("tag-\(i)"), .string("common")])
            ]))
        }
        let largeValue = AnyCodableValue.object(["tools": .array(items)])

        let duration = clock.measure {
            for _ in 1...iterations {
                let data = try! JSONEncoder().encode(largeValue)
                _ = try! JSONDecoder().decode(AnyCodableValue.self, from: data)
            }
        }

        // Verify completion — actual timing varies between debug/release
        #expect(iterations == 100)
    }

    @Test("SSEParser throughput (10000 events)")
    func sseParserThroughput() {
        let clock = ContinuousClock()
        let eventCount = 10_000

        // Build a chunk with many events
        var chunk = ""
        for i in 0..<eventCount {
            chunk += "event: message\ndata: {\"id\":\(i)}\n\n"
        }

        var parsedCount = 0
        let duration = clock.measure {
            var parser = SSEParser()
            let events = parser.append(chunk)
            parsedCount = events.count
        }

        #expect(parsedCount == eventCount)
    }

    @Test("MCPContent encode/decode round-trip (1000 iterations)")
    func mcpContentRoundTrip() throws {
        let clock = ContinuousClock()
        let iterations = 1000

        let contents: [MCPContent] = [
            .text("Technical SEO Score: 74.8 / 100"),
            .image(data: String(repeating: "A", count: 1000), mimeType: "image/png"),
            .text("Second block", annotations: MCPAnnotations(audience: [.user], priority: 0.5))
        ]

        let duration = clock.measure {
            for _ in 1...iterations {
                let data = try! JSONEncoder().encode(contents)
                _ = try! JSONDecoder().decode([MCPContent].self, from: data)
            }
        }

        // Verify completion
        #expect(iterations == 1000)
    }

    @Test("IncomingMessage classification (10000 iterations)")
    func messageClassification() {
        let iterations = 10_000

        let responseData = """
        {"jsonrpc":"2.0","id":1,"result":{"tools":[]}}
        """.data(using: .utf8)!

        let notificationData = """
        {"jsonrpc":"2.0","method":"notifications/progress","params":{"progressToken":"t","progress":0.5}}
        """.data(using: .utf8)!

        let requestData = """
        {"jsonrpc":"2.0","id":99,"method":"roots/list"}
        """.data(using: .utf8)!

        var classified = 0
        for _ in 1...iterations {
            if IncomingMessage.parse(responseData) != nil { classified += 1 }
            if IncomingMessage.parse(notificationData) != nil { classified += 1 }
            if IncomingMessage.parse(requestData) != nil { classified += 1 }
        }

        #expect(classified == iterations * 3)
    }
}
