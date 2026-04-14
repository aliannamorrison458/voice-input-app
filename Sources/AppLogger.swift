import Foundation

enum AppLogger {
    private static let queue = DispatchQueue(label: "voice-input.logger")
    private static let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static var logFileURL: URL {
        Config.configDirURL.appendingPathComponent("log.txt")
    }

    static func info(_ message: String) {
        write(level: "INFO", message: message)
    }

    static func warn(_ message: String) {
        write(level: "WARN", message: message)
    }

    static func error(_ message: String) {
        write(level: "ERROR", message: message)
    }

    private static func write(level: String, message: String) {
        queue.async {
            do {
                try FileManager.default.createDirectory(at: Config.configDirURL, withIntermediateDirectories: true)
                if !FileManager.default.fileExists(atPath: logFileURL.path) {
                    FileManager.default.createFile(atPath: logFileURL.path, contents: Data(), attributes: nil)
                }

                let ts = formatter.string(from: Date())
                let line = "[\(ts)] [\(level)] \(message)\n"
                guard let data = line.data(using: .utf8),
                      let handle = try? FileHandle(forWritingTo: logFileURL) else { return }
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } catch {
                // Avoid recursive logging loops.
            }
        }
    }
}
