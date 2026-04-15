import Foundation

public enum AppLogger {
    private static let queue = DispatchQueue(label: "voice-input.logger")
    private static let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    /// Max log file size before rotation (5 MB)
    private static let maxLogSize: UInt64 = 5 * 1024 * 1024

    private static var logFileURL: URL {
        Config.configDirURL.appendingPathComponent("log.txt")
    }

    private static var logFileBackupURL: URL {
        Config.configDirURL.appendingPathComponent("log.old.txt")
    }

    public static func info(_ message: String) {
        write(level: "INFO", message: message)
    }

    public static func warn(_ message: String) {
        write(level: "WARN", message: message)
    }

    public static func error(_ message: String) {
        write(level: "ERROR", message: message)
    }

    private static func write(level: String, message: String) {
        queue.async {
            do {
                try FileManager.default.createDirectory(at: Config.configDirURL, withIntermediateDirectories: true)

                // Rotate if file is too large
                rotateIfNeeded()

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

    private static func rotateIfNeeded() {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: logFileURL.path),
              let fileSize = attrs[.size] as? UInt64,
              fileSize > maxLogSize else { return }

        let fm = FileManager.default
        // Remove old backup if exists
        if fm.fileExists(atPath: logFileBackupURL.path) {
            try? fm.removeItem(at: logFileBackupURL)
        }
        // Move current log to backup
        try? fm.moveItem(at: logFileURL, to: logFileBackupURL)
        // Note: don't call AppLogger.info() here — we're already inside write()
        // on the serial queue, which would cause a recursive dispatch.
    }
}
