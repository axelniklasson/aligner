import Foundation

/// Opt-in logging to stderr, enabled with `ALIGNER_DEBUG=1`.
enum Debug {
    static let enabled = ProcessInfo.processInfo.environment["ALIGNER_DEBUG"] != nil

    static func log(_ message: @autoclosure () -> String) {
        guard enabled else { return }
        FileHandle.standardError.write(Data((message() + "\n").utf8))
    }
}
