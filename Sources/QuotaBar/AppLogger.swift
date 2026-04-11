import Foundation

actor AppLogger {
    static let shared = AppLogger()

    private let fileURL: URL
    private let formatter: ISO8601DateFormatter

    private init() {
        let libraryDirectory = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library", isDirectory: true)
        let logsDirectory = libraryDirectory
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("QuotaBar", isDirectory: true)

        try? FileManager.default.createDirectory(at: logsDirectory, withIntermediateDirectories: true)
        fileURL = logsDirectory.appendingPathComponent("app.log", isDirectory: false)

        formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    }

    nonisolated static var logFilePath: String {
        let libraryDirectory = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library", isDirectory: true)
        return libraryDirectory
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("QuotaBar", isDirectory: true)
            .appendingPathComponent("app.log", isDirectory: false)
            .path
    }

    func info(_ message: String) {
        write(level: "INFO", message: message)
    }

    func error(_ message: String) {
        write(level: "ERROR", message: message)
    }

    func debug(_ message: String) {
        write(level: "DEBUG", message: message)
    }

    private func write(level: String, message: String) {
        let line = "[\(formatter.string(from: Date()))] [\(level)] \(message)\n"
        let data = Data(line.utf8)

        if FileManager.default.fileExists(atPath: fileURL.path) == false {
            FileManager.default.createFile(atPath: fileURL.path, contents: data)
            return
        }

        do {
            let handle = try FileHandle(forWritingTo: fileURL)
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.close()
        } catch {
            NSLog("[QuotaBar] 日志写入失败: %@", error.localizedDescription)
        }
    }
}

enum Log {
    static func info(_ message: String) {
        Task { await AppLogger.shared.info(message) }
    }

    static func error(_ message: String) {
        Task { await AppLogger.shared.error(message) }
    }

    static func debug(_ message: String) {
        Task { await AppLogger.shared.debug(message) }
    }
}
