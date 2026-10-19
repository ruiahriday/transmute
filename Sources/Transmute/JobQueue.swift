import AppKit
import Combine
import Foundation

enum JobState: Equatable {
    case queued
    case running(Double)
    case done(JobResult)
    case failed(String)

    var isFinished: Bool {
        switch self {
        case .done, .failed: true
        default: false
        }
    }

    var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }

    var fraction: Double {
        switch self {
        case .queued: 0
        case .running(let p): p
        case .done, .failed: 1
        }
    }
}

struct Job: Identifiable {
    let id = UUID()
    let url: URL
    let kind: FileKind
    let size: Int64
    var state: JobState = .queued

    init(url: URL) {
        self.url = url
        self.kind = FileKind.of(url)
        self.size = OutputPaths.fileSize(url)
    }
}

@MainActor
final class JobQueue: ObservableObject {
    static let shared = JobQueue()

    @Published private(set) var jobs: [Job] = []
    @Published private(set) var activeBatches = 0
    private var tasks: [Task<Void, Never>] = []

    /// How many files convert at once. ffmpeg is multithreaded itself, so keep this small.
    private let concurrency = 2

    var isRunning: Bool { activeBatches > 0 }

    var kindsPresent: [FileKind] {
        FileKind.allCases.filter { kind in jobs.contains { $0.kind == kind } }
    }

    /// Adds files (folders are expanded). Returns the job ids, reusing existing jobs for files already listed.
    @discardableResult
    func add(_ urls: [URL]) -> [UUID] {
        var ids: [UUID] = []
        for url in Self.expand(urls) {
            if let index = jobs.firstIndex(where: { $0.url == url }) {
                if !isActive(jobs[index].state) { jobs[index].state = .queued }
                ids.append(jobs[index].id)
            } else {
                let job = Job(url: url)
                jobs.append(job)
                ids.append(job.id)
            }
        }
        return ids
    }

    func remove(_ id: UUID) {
        jobs.removeAll { $0.id == id && !isActive($0.state) }
    }

    func clear() {
        jobs.removeAll { !isActive($0.state) }
    }

    func cancelAll() {
        tasks.forEach { $0.cancel() }
    }

    func job(_ id: UUID) -> Job? { jobs.first { $0.id == id } }

    private func isActive(_ state: JobState) -> Bool {
        if case .running = state { return true }
        return false
    }

    private func setState(_ id: UUID, _ state: JobState) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[index].state = state
    }

    private func updateProgress(_ id: UUID, _ fraction: Double) {
        guard let index = jobs.firstIndex(where: { $0.id == id }), case .running = jobs[index].state else { return }
        jobs[index].state = .running(fraction)
    }

    static func expand(_ urls: [URL]) -> [URL] {
        var result: [URL] = []
        let fm = FileManager.default
        for url in urls {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            guard isDir.boolValue, !url.pathExtension.lowercased().hasSuffix("app") else {
                result.append(url)
                continue
            }
            let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey],
                                           options: [.skipsHiddenFiles, .skipsPackageDescendants])
            while let file = enumerator?.nextObject() as? URL {
                if (try? file.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
                    result.append(file)
                }
            }
        }
        return result
    }

    // MARK: Running

    func start(_ plan: [(UUID, JobOperation)], options: ConversionOptions, reveal: Bool,
               onFinish: (@MainActor () -> Void)? = nil) {
        guard !plan.isEmpty else { onFinish?(); return }
        // Decide every output folder now, on the main actor (the App Store build may ask).
        let optionsFor = FolderAccess.prepare(plan.compactMap { job($0.0)?.url }, options: options)
        let work: [(UUID, JobOperation, ConversionOptions)] = plan.map { entry in
            let jobOptions: ConversionOptions = job(entry.0).map { optionsFor($0.url) } ?? options
            return (entry.0, entry.1, jobOptions)
        }
        for (id, _) in plan { setState(id, .queued) }
        activeBatches += 1
        let task = Task { [weak self] in
            guard let self else { return }
            await self.process(work)
            self.activeBatches -= 1
            if reveal { self.reveal(ids: plan.map(\.0)) }
            onFinish?()
        }
        tasks.append(task)
    }

    func runBatch(_ tool: BatchTool, ids: [UUID], options: ConversionOptions, reveal: Bool) {
        let urls = ids.compactMap { job($0)?.url }
        guard !urls.isEmpty else { return }
        // A batch makes one file, next to the first input unless a folder is set.
        let batchOptions = FolderAccess.prepare([urls[0]], options: options)(urls[0])
        ids.forEach { setState($0, .running(0)) }
        activeBatches += 1
        let task = Task { [weak self] in
            do {
                let output = try await Engine.batch(tool, urls: urls, options: batchOptions)
                ids.forEach { self?.setState($0, .done(JobResult(outputs: [output]))) }
                if reveal { NSWorkspace.shared.activateFileViewerSelecting([output]) }
            } catch {
                ids.forEach { self?.setState($0, .failed(error.localizedDescription)) }
            }
            self?.activeBatches -= 1
        }
        tasks.append(task)
    }

    private func process(_ plan: [(UUID, JobOperation, ConversionOptions)]) async {
        var next = 0
        await withTaskGroup(of: Void.self) { group in
            while next < min(concurrency, plan.count) {
                let (id, op, options) = plan[next]
                next += 1
                group.addTask { await self.runOne(id, op, options) }
            }
            while await group.next() != nil {
                if next < plan.count {
                    let (id, op, options) = plan[next]
                    next += 1
                    group.addTask { await self.runOne(id, op, options) }
                }
            }
        }
    }

    private func runOne(_ id: UUID, _ operation: JobOperation, _ options: ConversionOptions) async {
        guard let job = job(id) else { return }
        if Task.isCancelled { setState(id, .failed("Cancelled")); return }
        setState(id, .running(0))
        do {
            let result = try await Engine.perform(operation, on: job.url, options: options) { fraction in
                Task { @MainActor [weak self] in self?.updateProgress(id, fraction) }
            }
            setState(id, .done(result))
        } catch is CancellationError {
            setState(id, .failed("Cancelled"))
        } catch {
            setState(id, .failed(Task.isCancelled ? "Cancelled" : error.localizedDescription))
        }
    }

    private func reveal(ids: [UUID]) {
        let outputs = ids.compactMap { id -> [URL]? in
            if case .done(let result) = job(id)?.state { return result.outputs }
            return nil
        }.flatMap { $0 }
        if !outputs.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(outputs) }
    }
}
