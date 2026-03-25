import Foundation

/// A mock URL protocol that intercepts URLSession requests for deterministic testing.
///
/// Register canned responses before making requests. Supports both regular HTTP
/// responses and streaming SSE responses.
///
/// ## Usage
///
/// ```swift
/// MockURLProtocol.reset()
/// MockURLProtocol.registerResponse(
///     for: "https://example.com/sse",
///     statusCode: 200,
///     headers: ["Content-Type": "text/event-stream"],
///     body: "event: endpoint\ndata: /messages\n\n".data(using: .utf8)!
/// )
/// let config = URLSessionConfiguration.ephemeral
/// config.protocolClasses = [MockURLProtocol.self]
/// let session = URLSession(configuration: config)
/// ```
final class MockURLProtocol: URLProtocol, @unchecked Sendable {

    /// Stored mock responses keyed by URL string.
    private nonisolated(unsafe) static var responses: [String: MockResponse] = [:]
    private nonisolated(unsafe) static var lock = NSLock()

    /// Recorded requests for verification.
    private nonisolated(unsafe) static var recordedRequests: [URLRequest] = []

    struct MockResponse: Sendable {
        let statusCode: Int
        let headers: [String: String]
        let body: Data
        let error: Error?

        init(statusCode: Int, headers: [String: String] = [:], body: Data = Data(), error: Error? = nil) {
            self.statusCode = statusCode
            self.headers = headers
            self.body = body
            self.error = error
        }
    }

    /// Reset all registered responses and recorded requests.
    static func reset() {
        lock.lock()
        defer { lock.unlock() }
        responses.removeAll()
        recordedRequests.removeAll()
    }

    /// Register a canned response for a given URL.
    static func registerResponse(
        for urlString: String,
        statusCode: Int,
        headers: [String: String] = [:],
        body: Data = Data()
    ) {
        lock.lock()
        defer { lock.unlock() }
        responses[urlString] = MockResponse(statusCode: statusCode, headers: headers, body: body)
    }

    /// Register an error response for a given URL.
    static func registerError(for urlString: String, error: Error) {
        lock.lock()
        defer { lock.unlock() }
        responses[urlString] = MockResponse(statusCode: 0, error: error)
    }

    /// Get all recorded requests.
    static func getRecordedRequests() -> [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return recordedRequests
    }

    // MARK: - URLProtocol overrides

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        MockURLProtocol.lock.lock()
        MockURLProtocol.recordedRequests.append(request)
        let urlString = request.url?.absoluteString ?? ""
        let mockResponse = MockURLProtocol.responses[urlString]
        MockURLProtocol.lock.unlock()

        if let mockResponse = mockResponse {
            if let error = mockResponse.error {
                client?.urlProtocol(self, didFailWithError: error)
                return
            }

            let response = HTTPURLResponse(
                url: request.url ?? URL(string: "https://mock")!,
                statusCode: mockResponse.statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: mockResponse.headers
            )

            if let response = response {
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            }
            client?.urlProtocol(self, didLoad: mockResponse.body)
            client?.urlProtocolDidFinishLoading(self)
        } else {
            let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotConnectToHost)
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {
        // Nothing to clean up
    }
}
