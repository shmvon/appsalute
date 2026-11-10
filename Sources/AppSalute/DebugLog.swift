import Foundation

/// Minimal file logger: ~/Library/Logs/AppSalute.log
enum DebugLog {
    static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/AppSalute.log")

    static func reset() { try? "".write(to: url, atomically: true, encoding: .utf8) }

    static func write(_ message: String) {
        let line = "\(Date()) \(message)\n"
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close()
        } else {
            try? line.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}
