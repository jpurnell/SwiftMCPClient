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
/// ## Platform Availability
///
/// StdioTransport requires `Foundation.Process` and is only available on macOS and Linux.
/// It is not available on iOS, tvOS, or watchOS.
public actor StdioTransport: MCPTransport {
    private let command: String
    private let arguments: [String]
    private let environment: [String: String]

    private var process: Process?
    private var stdinPipe: Pipe?
    private var stdoutPipe: Pipe?
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
    public init(
        command: String,
        arguments: [String] = [],
        environment: [String: String] = [:]
    ) {
        self.command = command
        self.arguments = arguments
        self.environment = environment
    }

    /// Spawn the MCP server subprocess and configure stdin/stdout pipes.
    ///
    /// - Throws: ``MCPError/processSpawnFailed(reason:)`` if the process cannot be launched.
    public func connect() async throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: command)
        proc.arguments = arguments

        // Merge additional environment with current process environment
        var env = ProcessInfo.processInfo.environment
        for (key, value) in environment {
            env[key] = value
        }
        proc.environment = env

        let stdin = Pipe()
        let stdout = Pipe()

        proc.standardInput = stdin
        proc.standardOutput = stdout
        // Capture stderr to prevent it from mixing with our output
        proc.standardError = Pipe()

        do {
            try proc.run()
        } catch {
            throw MCPError.processSpawnFailed(reason: error.localizedDescription)
        }

        self.process = proc
        self.stdinPipe = stdin
        self.stdoutPipe = stdout
        self.isConnected = true
    }

    /// Close the subprocess connection.
    ///
    /// Performs a graceful shutdown sequence:
    /// 1. Close stdin to signal the server
    /// 2. Wait briefly for the process to exit
    /// 3. Send SIGTERM if still running
    /// 4. Send SIGKILL as a last resort
    public func disconnect() async throws {
        guard let proc = process else { return }

        isConnected = false

        // Close stdin to signal the server to shut down
        stdinPipe?.fileHandleForWriting.closeFile()

        // Give the process time to exit gracefully
        if proc.isRunning {
            try await Task.sleep(for: .milliseconds(100))
        }

        // SIGTERM if still running
        if proc.isRunning {
            proc.terminate()
            try await Task.sleep(for: .milliseconds(100))
        }

        // SIGKILL as last resort
        #if os(macOS)
        if proc.isRunning {
            kill(proc.processIdentifier, SIGKILL)
        }
        #endif

        process = nil
        stdinPipe = nil
        stdoutPipe = nil
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
        guard isConnected, let pipe = stdinPipe, let proc = process else {
            throw MCPError.connectionFailed(reason: "StdioTransport is not connected")
        }

        guard proc.isRunning else {
            isConnected = false
            throw MCPError.transportClosed
        }

        // Write data + newline delimiter
        var messageData = data
        messageData.append(contentsOf: [0x0A]) // newline
        pipe.fileHandleForWriting.write(messageData)
    }

    /// Receive the next JSON-RPC message from the subprocess via stdout.
    ///
    /// Reads from the process's stdout until a complete newline-delimited
    /// JSON message is available.
    ///
    /// - Returns: The JSON-RPC message data (without the trailing newline).
    /// - Throws: ``MCPError/connectionFailed(reason:)`` if not connected.
    /// - Throws: ``MCPError/transportClosed`` if the process has exited and no data remains.
    public func receive() async throws -> Data {
        guard isConnected, let pipe = stdoutPipe else {
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
        let handle = pipe.fileHandleForReading
        while true {
            let chunk = handle.availableData

            if chunk.isEmpty {
                // EOF — process closed stdout
                isConnected = false
                throw MCPError.transportClosed
            }

            guard let text = String(data: chunk, encoding: .utf8) else {
                continue
            }

            readBuffer.append(text)

            // Split on newlines
            let lines = readBuffer.split(separator: "\n", omittingEmptySubsequences: false)
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
    }
}

#endif
