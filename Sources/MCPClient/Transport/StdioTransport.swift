import Foundation

#if os(macOS) || os(Linux)

/// Spawns an MCP server as a local subprocess and communicates via stdin/stdout pipes.
///
/// This transport launches an MCP server executable as a child process and communicates
/// using newline-delimited JSON over stdin (sending) and stdout (receiving), per the
/// MCP specification.
///
/// ## Usage
///
/// ```swift
/// let transport = StdioTransport(command: "/usr/local/bin/my-mcp-server")
/// let client = MCPClientConnection(transport: transport)
/// let info = try await client.initialize(clientName: "my-app", clientVersion: "1.0.0")
/// ```
///
/// ## Subprocess Lifecycle
///
/// - ``connect()`` spawns the process with configured pipes
/// - ``send(_:)`` writes newline-delimited JSON to the process's stdin
/// - ``receive()`` reads the next line from the process's stdout
/// - ``disconnect()`` closes stdin, waits briefly, then sends SIGTERM/SIGKILL if needed
///
/// ## Message Size
///
/// A message is a line, and a line ends when the process writes a newline. One that never
/// does would be buffered until memory ran out, so a line is limited to
/// ``MCPResponseLimits/maximumMessageBytes`` — 10 MiB unless configured. A process that goes
/// past it is stopped, the transport is closed, and ``receive()`` throws
/// ``MCPError/responseTooLarge(limit:reason:)``: framing is lost part-way through a line, so
/// nothing after it on that stream can be trusted.
///
/// ## Platform Availability
///
/// StdioTransport requires `Foundation.Process` and is only available on macOS and Linux.
/// It is not available on iOS, tvOS, or watchOS.
public actor StdioTransport: MCPTransport {
    private let command: String
    private let arguments: [String]
    private let environment: [String: String]

    private let limits: MCPResponseLimits

    private var runner: ProcessRunner?
    private var bufferedLines: [String] = []
    private var readBuffer: String = ""
    private var isConnected: Bool = false

    /// Creates a new stdio transport.
    ///
    /// - Parameters:
    ///   - command: Path to the MCP server executable.
    ///   - arguments: Command-line arguments for the server. Defaults to empty.
    ///   - environment: Additional environment variables merged with the current
    ///     process environment. Defaults to empty.
    ///   - limits: How much one line from the process may hold before it is stopped; only
    ///     ``MCPResponseLimits/maximumMessageBytes`` applies. Defaults to
    ///     ``MCPResponseLimits/standard``, 10 MiB.
    public init(
        command: String,
        arguments: [String] = [],
        environment: [String: String] = [:],
        limits: MCPResponseLimits = .standard
    ) {
        self.command = command
        self.arguments = arguments
        self.environment = environment
        self.limits = limits
    }

    /// Spawn the MCP server subprocess and configure stdin/stdout pipes.
    ///
    /// - Throws: ``MCPError/processSpawnFailed(reason:)`` if the process cannot be launched.
    public func connect() async throws {
        runner = try ProcessRunner(
            command: command,
            arguments: arguments,
            environment: environment
        )
        isConnected = true
    }

    /// Close the subprocess connection.
    ///
    /// Performs a graceful shutdown sequence:
    /// 1. Close stdin to signal the server
    /// 2. Wait briefly for the process to exit
    /// 3. Send SIGTERM if still running
    /// 4. Send SIGKILL as a last resort
    public func disconnect() async throws {
        guard let runner else { return }

        isConnected = false
        await runner.shutdown()

        self.runner = nil
        bufferedLines = []
        readBuffer = ""
    }

    /// Send a JSON-RPC message to the subprocess via stdin.
    ///
    /// The message is written as a single line followed by a newline character,
    /// per the MCP stdio transport specification.
    ///
    /// - Parameter data: The JSON-RPC message data to send.
    /// - Throws: ``MCPError/connectionFailed(reason:)`` if not connected.
    /// - Throws: ``MCPError/transportClosed`` if the process has exited.
    public func send(_ data: Data) async throws {
        guard isConnected, let runner else {
            throw MCPError.connectionFailed(reason: "StdioTransport is not connected")
        }

        guard runner.isRunning else {
            isConnected = false
            throw MCPError.transportClosed
        }

        // Write data + newline delimiter
        var messageData = data
        messageData.append(contentsOf: [0x0A]) // newline
        try runner.write(messageData)
    }

    /// Receive the next JSON-RPC message from the subprocess via stdout.
    ///
    /// Reads from the process's stdout until a complete newline-delimited
    /// JSON message is available.
    ///
    /// - Returns: The JSON-RPC message data (without the trailing newline).
    /// - Throws: ``MCPError/connectionFailed(reason:)`` if not connected.
    /// - Throws: ``MCPError/transportClosed`` if the process has exited and no data remains.
    /// - Throws: ``MCPError/responseTooLarge(limit:reason:)`` if a line is longer than
    ///   ``MCPResponseLimits/maximumMessageBytes``. The process is stopped and the transport
    ///   is closed.
    public func receive() async throws -> Data {
        guard isConnected, let runner else {
            throw MCPError.connectionFailed(reason: "StdioTransport is not connected")
        }

        // Return buffered line if available
        if !bufferedLines.isEmpty {
            let line = bufferedLines.removeFirst()
            guard let data = line.data(using: .utf8) else {
                throw MCPError.invalidResponse
            }
            return data
        }

        // Read from stdout until we get a complete line
        while !Task.isCancelled {
            guard let chunk = await runner.nextChunk() else {
                // EOF — process closed stdout
                isConnected = false
                throw MCPError.transportClosed
            }

            guard let text = String(data: chunk, encoding: .utf8) else {
                continue
            }

            readBuffer.append(text)

            // No newline in what arrived: the line is still going. Nothing to frame, and no
            // reason to scan what is already held again — only to ask whether it is too long.
            guard text.contains(where: \.isNewline) else {
                guard readBuffer.utf8.count <= limits.maximumMessageBytes else {
                    throw await refuseOversizedMessage()
                }
                continue
            }

            // Split on newlines. `whereSeparator` matches any newline Character, so a server
            // that terminates with "\r\n" frames correctly — "\r\n" is one Character, and
            // splitting on the "\n" literal would never match it.
            let lines = readBuffer.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            // Every piece is held to the limit before any is kept: what the process sent
            // after an oversized line cannot be told apart from the rest of it.
            for line in lines where line.utf8.count > limits.maximumMessageBytes {
                throw await refuseOversizedMessage()
            }
            if lines.count > 1 {
                // We have at least one complete line
                for i in 0..<(lines.count - 1) {
                    let line = String(lines[i])
                    if !line.isEmpty {
                        bufferedLines.append(line)
                    }
                }
                // Keep the remainder (possibly incomplete last line)
                readBuffer = String(lines[lines.count - 1])

                if !bufferedLines.isEmpty {
                    let firstLine = bufferedLines.removeFirst()
                    guard let data = firstLine.data(using: .utf8) else {
                        throw MCPError.invalidResponse
                    }
                    return data
                }
            }
        }

        // Task was cancelled while reading
        throw MCPError.transportClosed
    }

    /// Stops the process and closes the transport after a line went past its limit.
    ///
    /// Framing is lost part-way through that line, so the stream cannot be read on from it;
    /// and a process that will not stop writing is not one to leave running.
    ///
    /// - Returns: The error to throw.
    private func refuseOversizedMessage() async -> MCPError {
        isConnected = false
        let stopped = runner
        runner = nil
        bufferedLines = []
        readBuffer = ""
        await stopped?.shutdown()
        return MCPResponseLimits.exceeded(limits.maximumMessageBytes, reading: "message", from: nil)
    }
}

#endif
