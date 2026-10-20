import Foundation

/// Locates optional command-line helpers. GUI apps don't inherit the shell PATH,
/// so we look in the usual Homebrew locations and inside the app bundle.
/// The App Store build only ever uses the ffmpeg inside the app bundle.
enum Tools {
    static var ffmpeg: String? {
        // Lets the self-test exercise the Apple-only fallbacks.
        if ProcessInfo.processInfo.environment["TRANSMUTE_NO_FFMPEG"] != nil { return nil }
        #if APPSTORE
        let candidates = [Bundle.main.path(forAuxiliaryExecutable: "ffmpeg")]
        #else
        let candidates = [
            Bundle.main.path(forAuxiliaryExecutable: "ffmpeg"),
            "/opt/homebrew/bin/ffmpeg",
            "/usr/local/bin/ffmpeg",
        ]
        #endif
        return candidates.compactMap { $0 }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// What to tell the user when ffmpeg is missing.
    static var missingFFmpegHint: String {
        #if APPSTORE
        "The ffmpeg that comes with \(AppInfo.name) is missing; reinstall the app."
        #else
        "Install it once with: brew install ffmpeg"
        #endif
    }

    static func requireFFmpeg(for what: String) throws -> String {
        guard let path = ffmpeg else {
            throw ConversionError("\(what) needs ffmpeg. \(missingFFmpegHint)")
        }
        return path
    }
}

/// The app's name as shown to users (the App Store build sets its own at build time).
enum AppInfo {
    static var name: String {
        let info = Bundle.main.infoDictionary
        let display = info?["CFBundleDisplayName"] as? String ?? info?["CFBundleName"] as? String
        return display.flatMap { $0.isEmpty ? nil : $0 } ?? "Transmute"
    }

    static var isAppStoreBuild: Bool {
        #if APPSTORE
        true
        #else
        false
        #endif
    }
}

/// Picks encoders the bundled ffmpeg actually has. The download build's ffmpeg includes
/// libx264; the App Store build's ffmpeg is LGPL-only and encodes H.264 with Apple's
/// VideoToolbox instead.
enum Encoders {
    /// Names of the encoders the current ffmpeg offers (empty without ffmpeg).
    static let available: Set<String> = {
        guard let ffmpeg = Tools.ffmpeg else { return [] }
        let output = runSync(ffmpeg, ["-hide_banner", "-encoders"])
        var names = Set<String>()
        for line in output.split(whereSeparator: \.isNewline) {
            // " V....D libx264              libx264 H.264 ..."
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 2, parts[0].count == 6 else { continue }
            names.insert(String(parts[1]))
        }
        return names
    }()

    static func has(_ name: String) -> Bool { available.contains(name) }

    /// VideoToolbox's constant-quality mode (-q:v) needs Apple-silicon hardware; Intel Macs
    /// and virtual machines without a hardware encoder only take a bitrate.
    private static let videoToolboxQuality: Bool = {
        guard let ffmpeg = Tools.ffmpeg else { return false }
        let args = ["-hide_banner", "-nostdin", "-loglevel", "error", "-f", "lavfi",
                    "-i", "color=c=gray:s=128x128:d=0.2", "-c:v", "h264_videotoolbox",
                    "-q:v", "60", "-allow_sw", "1", "-f", "null", "-"]
        return runSyncStatus(ffmpeg, args) == 0
    }()

    /// H.264 video at about the quality of x264 at `crf` (lower is better).
    static func h264(crf: Int) -> [String] {
        if has("libx264") || !has("h264_videotoolbox") {
            return ["-c:v", "libx264", "-preset", "medium", "-crf", String(crf)]
        }
        if videoToolboxQuality {
            // Roughly: CRF 18 → 70, CRF 23 → 60, CRF 28 → 50.
            let quality = max(30, min(85, 106 - 2 * crf))
            return ["-c:v", "h264_videotoolbox", "-q:v", String(quality), "-allow_sw", "1"]
        }
        let bitrate = crf <= 20 ? "8M" : "5M"
        return ["-c:v", "h264_videotoolbox", "-b:v", bitrate, "-allow_sw", "1"]
    }

    /// H.264 video at an average bitrate (bits per second) with a peak limit.
    static func h264(bitrate: Int) -> [String] {
        let rate = String(bitrate)
        let peak = String(Int(Double(bitrate) * 1.4))
        if has("libx264") || !has("h264_videotoolbox") {
            return ["-c:v", "libx264", "-preset", "medium", "-b:v", rate, "-maxrate", peak,
                    "-bufsize", String(bitrate * 2)]
        }
        return ["-c:v", "h264_videotoolbox", "-b:v", rate, "-maxrate", peak, "-allow_sw", "1"]
    }

    private static func runSync(_ executable: String, _ arguments: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        guard (try? process.run()) != nil else { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    private static func runSyncStatus(_ executable: String, _ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return -1 }
        process.waitUntilExit()
        return process.terminationStatus
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
