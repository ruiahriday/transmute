import Foundation

/// Locates optional command-line helpers. GUI apps don't inherit the shell PATH,
/// so we look in the usual Homebrew locations and inside the app bundle.
enum Tools {
    static var ffmpeg: String? {
        // Lets the self-test exercise the Apple-only fallbacks.
        if ProcessInfo.processInfo.environment["TRANSMUTE_NO_FFMPEG"] != nil { return nil }
        let candidates = [
            bundledFFmpeg,
            "/opt/homebrew/bin/ffmpeg",
            "/usr/local/bin/ffmpeg",
        ]
        return candidates.compactMap { $0 }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// The ffmpeg inside the app. A downloaded app carries the download quarantine flag on every
    /// file in it, and macOS can refuse to start the bundled ffmpeg even after the app itself was
    /// allowed, which made every video conversion fail. The flag is cleared, or when the app can't
    /// be changed (for example when it runs from the disk image), an unflagged copy is used.
    private static let bundledFFmpeg: String? = {
        guard let bundled = Bundle.main.path(forAuxiliaryExecutable: "ffmpeg") else { return nil }
        let flag = "com.apple.quarantine"
        if getxattr(bundled, flag, nil, 0, 0, 0) < 0 || removexattr(bundled, flag, 0) == 0 { return bundled }
        let fm = FileManager.default
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        guard let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return bundled }
        let dir = support.appendingPathComponent("Transmute/ffmpeg-\(build)", isDirectory: true)
        let copy = dir.appendingPathComponent("ffmpeg")
        if !fm.fileExists(atPath: copy.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            guard (try? fm.copyItem(atPath: bundled, toPath: copy.path)) != nil else { return bundled }
        }
        removexattr(copy.path, flag, 0)
        chmod(copy.path, 0o755)
        return fm.isExecutableFile(atPath: copy.path) ? copy.path : bundled
    }()

    static func requireFFmpeg(for what: String) throws -> String {
        guard let path = ffmpeg else {
            throw ConversionError("\(what) needs ffmpeg. Install it once with: brew install ffmpeg")
        }
        return path
    }
}

/// Collects a process's output and calls back once per line.
private final class LineCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = Data()
    private var all = Data()
    private let onLine: (@Sendable (String) -> Void)?

    init(onLine: (@Sendable (String) -> Void)?) { self.onLine = onLine }

    /// Reads and appends as one step, so the final drain can't overtake a handler mid-read.
    private let readLock = NSLock()
    func read(from handle: FileHandle, toEnd: Bool) {
        readLock.lock()
        defer { readLock.unlock() }
        let data = toEnd ? handle.readDataToEndOfFile() : handle.availableData
        if !data.isEmpty { append(data) }
    }

    func append(_ data: Data) {
        var lines: [String] = []
        lock.lock()
        all.append(data)
        pending.append(data)
        while let end = pending.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
            lines.append(String(decoding: pending[pending.startIndex..<end], as: UTF8.self))
            pending.removeSubrange(pending.startIndex...end)
        }
        lock.unlock()
        lines.filter { !$0.isEmpty }.forEach { onLine?($0) }
    }

    func flush() {
        lock.lock()
        let rest = String(decoding: pending, as: UTF8.self)
        pending.removeAll()
        lock.unlock()
        if !rest.isEmpty { onLine?(rest) }
    }

    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: all, as: UTF8.self)
    }
}

enum Shell {
    struct Output {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    /// Runs a program and waits for it. Cancelling the calling task terminates the process.
    static func run(
        _ executable: String,
        _ arguments: [String],
        currentDirectory: URL? = nil,
        stdoutFile: URL? = nil,
        onStdoutLine: (@Sendable (String) -> Void)? = nil,
        onStderrLine: (@Sendable (String) -> Void)? = nil
    ) async throws -> Output {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let currentDirectory { process.currentDirectoryURL = currentDirectory }
        process.standardInput = FileHandle.nullDevice

        let outCollector = LineCollector(onLine: onStdoutLine)
        let errCollector = LineCollector(onLine: onStderrLine)
        let errPipe = Pipe()
        process.standardError = errPipe
        let outPipe: Pipe?
        if let stdoutFile {
            FileManager.default.createFile(atPath: stdoutFile.path, contents: nil)
            process.standardOutput = try FileHandle(forWritingTo: stdoutFile)
            outPipe = nil
        } else {
            let pipe = Pipe()
            outPipe = pipe
            process.standardOutput = pipe
        }
        outPipe?.fileHandleForReading.readabilityHandler = { outCollector.read(from: $0, toEnd: false) }
        errPipe.fileHandleForReading.readabilityHandler = { errCollector.read(from: $0, toEnd: false) }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Output, Error>) in
                process.terminationHandler = { finished in
                    outPipe?.fileHandleForReading.readabilityHandler = nil
                    errPipe.fileHandleForReading.readabilityHandler = nil
                    if let outPipe { outCollector.read(from: outPipe.fileHandleForReading, toEnd: true) }
                    errCollector.read(from: errPipe.fileHandleForReading, toEnd: true)
                    outCollector.flush()
                    errCollector.flush()
                    continuation.resume(returning: Output(
                        status: finished.terminationStatus,
                        stdout: outCollector.text,
                        stderr: errCollector.text
                    ))
                }
                do {
                    try process.run()
                } catch {
                    process.terminationHandler = nil
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
    }

    /// Like `run`, but throws with the tail of stderr when the exit status isn't 0.
    @discardableResult
    static func check(
        _ executable: String,
        _ arguments: [String],
        currentDirectory: URL? = nil,
        stdoutFile: URL? = nil,
        onStdoutLine: (@Sendable (String) -> Void)? = nil,
        onStderrLine: (@Sendable (String) -> Void)? = nil
    ) async throws -> Output {
        let output = try await run(
            executable, arguments,
            currentDirectory: currentDirectory, stdoutFile: stdoutFile,
            onStdoutLine: onStdoutLine, onStderrLine: onStderrLine
        )
        try Task.checkCancellation()
        guard output.status == 0 else {
            let tail = output.stderr
                .split(whereSeparator: \.isNewline)
                .suffix(3)
                .joined(separator: "\n")
            let tool = URL(fileURLWithPath: executable).lastPathComponent
            throw ConversionError(tail.isEmpty ? "\(tool) failed (exit code \(output.status))" : tail)
        }
        return output
    }
}
