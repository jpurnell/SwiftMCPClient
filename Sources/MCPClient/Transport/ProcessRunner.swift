import Foundation

#if os(macOS) || os(Linux)

/// The one place in MCPClient where a subprocess is spawned and its pipes are drained.
///
/// ## Why this exists
///
/// `FileHandle.availableData` blocks the calling thread until the pipe has bytes or the
/// writer closes it. Called in a loop from an actor — as a transport naturally wants to —
/// it parks a thread out of the cooperative pool for as long as the child stays quiet,
/// which under load is long enough to starve unrelated work.
///
/// `ProcessRunner` reads through `readabilityHandler` instead. That callback runs only once
/// the kernel already has bytes buffered or has seen EOF, so the `availableData` call inside
/// it returns immediately and never parks anything. Chunks are handed to callers through
/// ``nextChunk()``, which suspends rather than blocks.
///
/// ## Lifetime
///
/// An MCP server subprocess runs for as long as the session does, so there is no
/// total-run deadline to enforce here — the bound this type provides is on *reads*, which
/// no longer block, and on shutdown, which escalates rather than waiting forever.
///
/// ## Concurrency
///
/// ``nextChunk()`` supports a single consumer at a time. ``StdioTransport`` is an actor and
/// calls it serially, which is the only supported use.
// `process` and the pipes are set once in `init` and only read afterwards.
// Justification: every mutable stored property is private and reached only under `lock`.
final class ProcessRunner: @unchecked Sendable {

    private let process: Process
    private let stdinPipe: Pipe
    private let stdoutPipe: Pipe

    private let lock = NSLock()
    private var pendingChunks: [Data] = []
    private var waiter: CheckedContinuation<Data?, Never>?
    private var reachedEOF = false

    /// Spawns the command and begins draining its stdout.
    ///
    /// - Parameters:
    ///   - command: Path to the executable.
    ///   - arguments: Command-line arguments.
    ///   - environment: Variables merged over the current process environment.
    /// - Throws: ``MCPError/processSpawnFailed(reason:)`` if the process cannot be launched.
    init(command: String, arguments: [String], environment: [String: String]) throws {
        // SECURITY: command path and arguments are caller-controlled configuration, not user input
        process = Process()
        process.executableURL = URL(fileURLWithPath: command)
        process.arguments = arguments

        var mergedEnvironment = ProcessInfo.processInfo.environment
        for (key, value) in environment {
            mergedEnvironment[key] = value
        }
        process.environment = mergedEnvironment

        stdinPipe = Pipe()
        stdoutPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        // Captured so the child's diagnostics cannot interleave with our own output.
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            throw MCPError.processSpawnFailed(reason: error.localizedDescription)
        }

        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            // Bytes are already buffered or the writer has closed, so this does not block.
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                self?.deliver(nil)
            } else {
                self?.deliver(chunk)
            }
        }
    }

    /// Whether the child process is still running.
    var isRunning: Bool { process.isRunning }

    /// Writes to the child's stdin.
    ///
    /// - Parameter data: The bytes to write.
    /// - Throws: ``MCPError/transportClosed`` if the process has already exited.
    func write(_ data: Data) throws {
        guard process.isRunning else { throw MCPError.transportClosed }
        stdinPipe.fileHandleForWriting.write(data)
    }

    /// The next chunk of the child's stdout, or `nil` once it closes.
    ///
    /// Suspends until bytes arrive. Supports one consumer at a time.
    func nextChunk() async -> Data? {
        await withCheckedContinuation { continuation in
            lock.lock()
            if !pendingChunks.isEmpty {
                let chunk = pendingChunks.removeFirst()
                lock.unlock()
                continuation.resume(returning: chunk)
            } else if reachedEOF {
                lock.unlock()
                continuation.resume(returning: nil)
            } else {
                waiter = continuation
                lock.unlock()
            }
        }
    }

    /// Ends the child process, escalating until it is gone.
    ///
    /// Closes stdin first so a well-behaved server can exit on its own, then SIGTERM, then
    /// SIGKILL. Each step is bounded, so this returns whether or not the child cooperates.
    func shutdown() async {
        stdinPipe.fileHandleForWriting.closeFile()

        if process.isRunning {
            try? await Task.sleep(for: .milliseconds(100))
        }
        if process.isRunning {
            process.terminate()
            try? await Task.sleep(for: .milliseconds(100))
        }
        #if os(macOS)
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
        #endif

        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        deliver(nil)
    }

    /// Hands a chunk to a waiting consumer, or queues it. `nil` marks end of output.
    private func deliver(_ chunk: Data?) {
        lock.lock()
        let resuming = waiter
        waiter = nil

        if let chunk {
            if resuming == nil {
                pendingChunks.append(chunk)
            }
        } else {
            guard !reachedEOF else {
                lock.unlock()
                return
            }
            reachedEOF = true
        }
        lock.unlock()

        resuming?.resume(returning: chunk)
    }
}

#endif
