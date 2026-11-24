import Foundation
import Logging

/// Keeps what a `Logger` was asked to write, so a test can read it.
///
/// `swift-log` is bootstrapped once per process, which a test cannot do without deciding for
/// every other test in it. A `Logger` made with its own handler needs no bootstrap: the
/// transports, the dispatcher and the event stream each take one, and the tests hand them
/// one of these.
// Justification: the only mutable state is `entries`, private and reached only under `lock`.
final class LogRecorder: @unchecked Sendable {

    /// One line, as it was written.
    struct Entry: Sendable, Equatable {
        let level: Logger.Level
        let message: String
    }

    private let lock = NSLock()
    private var entries: [Entry] = []

    /// Everything written so far, in order.
    var all: [Entry] {
        lock.lock()
        defer { lock.unlock() }
        return entries
    }

    /// The messages written at one level.
    func messages(at level: Logger.Level) -> [String] {
        all.filter { $0.level == level }.map(\.message)
    }

    fileprivate func record(_ entry: Entry) {
        lock.lock()
        defer { lock.unlock() }
        entries.append(entry)
    }

    /// A logger that writes here, at every level.
    func logger(label: String = "MCPClient.test") -> Logger {
        Logger(label: label) { _ in RecordingHandler(recorder: self) }
    }
}

/// The handler behind ``LogRecorder/logger(label:)``.
private struct RecordingHandler: LogHandler {
    let recorder: LogRecorder
    var metadata: Logger.Metadata = [:]
    var logLevel: Logger.Level = .trace

    subscript(metadataKey key: String) -> Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }

    func log(event: LogEvent) {
        recorder.record(.init(level: event.level, message: event.message.description))
    }
}
