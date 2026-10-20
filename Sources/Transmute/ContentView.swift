import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject private var queue: JobQueue

    @AppStorage(Prefs.imageQuality) private var quality = 0.85
    @AppStorage(Prefs.stripMetadata) private var stripMetadata = false
    @AppStorage(Prefs.revealWhenDone) private var revealWhenDone = true

    @State private var mode: Mode = .convert
    @State private var choices: [FileKind: OutputFormat] = [:]
    @State private var compressBy: CompressBy = .percent
    @State private var percent = 50.0
    @State private var targetMB = "5"
    @State private var dropTargeted = false
    @State private var showSettings = false
    @State private var showImporter = false
    @State private var editing: EditRequest?

    enum Mode: String, CaseIterable, Identifiable {
        case convert = "Convert", compress = "Compress", tools = "Tools"
        var id: String { rawValue }
    }

    enum CompressBy { case percent, size }

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if queue.jobs.isEmpty { emptyState } else { fileList }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            controls.padding(16)
        }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            load(providers)
            return true
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result {
                // Sandboxed: files picked here come with a security scope that must be opened.
                if AppInfo.isAppStoreBuild { urls.forEach(FolderAccess.beginAccess) }
                queue.add(urls)
            }
        }
        .toolbar {
            ToolbarItemGroup {
                Button { showImporter = true } label: { Label("Add Files", systemImage: "plus") }
                Button { queue.clear() } label: { Label("Clear List", systemImage: "trash") }
                    .disabled(queue.jobs.isEmpty)
                Button { showSettings = true } label: { Label("Settings", systemImage: "gearshape") }
            }
        }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .sheet(item: $editing) { request in editor(for: request) }
        .frame(minWidth: 600, minHeight: 460)
    }

    // MARK: File list

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "arrow.down.doc")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("Drop files or folders here")
                .font(.title2.weight(.semibold))
            Text("Images, video, audio, PDFs, documents, e-books, spreadsheets, presentations, subtitles and archives")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Choose Files…") { showImporter = true }
                .controlSize(.large)
            if WheelKind.convert.key != .off {
                Text("Tip: hold \(WheelKind.convert.key.label) while dragging a file anywhere to convert it on the spot.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.top, 8)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8]))
                .foregroundStyle(dropTargeted ? Color.accentColor : Color.secondary.opacity(0.4))
                .padding(20)
        )
    }

    private var fileList: some View {
        List {
            ForEach(queue.jobs) { job in
                JobRow(
                    job: job,
                    onEdit: editAction(for: job),
                    onInfo: infoAction(for: job),
                    onRemove: { queue.remove(job.id) }
                )
            }
        }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.accentColor, lineWidth: 3)
                    .padding(4)
            }
        }
    }

    private func load(_ providers: [NSItemProvider]) {
        let queue = self.queue
        for provider in providers {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                DispatchQueue.main.async { queue.add([url]) }
            }
        }
    }

    // MARK: Editors

    @ViewBuilder
    private func editor(for request: EditRequest) -> some View {
        let id = request.jobID
        let close = { editing = nil }
        switch request.mode {
        case .image:
            ImageEditorView(url: request.url, onSave: { edit in
                close()
                run(id, .editImage(edit))
            }, onCancel: close)
        case .video:
            VideoEditorView(url: request.url, onSave: { edit in
                close()
                run(id, .editVideo(edit))
            }, onSnapshot: { seconds in
                run(id, .snapshot(seconds: seconds))
            }, onCancel: close)
        case .audio:
            AudioEditorView(url: request.url, onSave: { edit in
                close()
                run(id, .editAudio(edit))
            }, onCancel: close)
        case .info:
            MetadataEditorView(url: request.url, onSave: { edit in
                close()
                run(id, .writeMetadata(edit))
            }, onCancel: close)
        }
    }

    private func editAction(for job: Job) -> (() -> Void)? {
        guard let mode = EditRequest.editMode(for: job.kind) else { return nil }
        return { editing = EditRequest(job: job, mode: mode) }
    }

    private func infoAction(for job: Job) -> (() -> Void)? {
        guard EditRequest.hasInfo(job.kind) else { return nil }
        return { editing = EditRequest(job: job, mode: .info) }
    }

    private func run(_ id: UUID, _ operation: JobOperation) {
        queue.start([(id, operation)], options: .fromDefaults(), reveal: revealWhenDone)
    }

    // MARK: Controls

    private var controls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Mode", selection: $mode) {
                ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            switch mode {
            case .convert: convertControls
            case .compress: compressControls
            case .tools: toolsControls
            }
        }
    }

    private var convertControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            if queue.kindsPresent.isEmpty {
                Text("Add some files to choose output formats.").foregroundStyle(.secondary)
            }
            ForEach(queue.kindsPresent) { kind in
                Picker(selection: format(for: kind)) {
                    ForEach(kind.convertTargets) { Text($0.label).tag($0) }
                } label: {
                    Label(kind.title, systemImage: kind.symbol).frame(width: 120, alignment: .leading)
                }
                .frame(maxWidth: 320)
            }
            HStack(spacing: 12) {
                if queue.kindsPresent.contains(.image) || queue.kindsPresent.contains(.pdf) {
                    Text("Quality")
                    Slider(value: $quality, in: 0.1...1).frame(width: 140)
                    Text("\(Int(quality * 100))%").monospacedDigit().frame(width: 40, alignment: .leading)
                }
                Toggle("Remove metadata", isOn: $stripMetadata)
                Spacer()
                actionButtons(title: "Convert") {
                    let plan = queue.jobs.map { job in
                        (job.id, JobOperation.convert(choices[job.kind] ?? job.kind.convertTargets[0]))
                    }
                    queue.start(plan, options: .fromDefaults(), reveal: revealWhenDone)
                }
            }
        }
    }

    private func format(for kind: FileKind) -> Binding<OutputFormat> {
        Binding(get: { choices[kind] ?? kind.convertTargets[0] }, set: { choices[kind] = $0 })
    }

    private var compressControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Picker("Compress by", selection: $compressBy) {
                    Text("Percentage").tag(CompressBy.percent)
                    Text("Target size").tag(CompressBy.size)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 200)
                if compressBy == .percent {
                    Slider(value: $percent, in: 10...90, step: 5).frame(width: 160)
                    Text("to \(Int(percent))% of original").monospacedDigit()
                } else {
                    TextField("MB", text: $targetMB).frame(width: 60)
                    Text("MB per file")
                }
                Spacer()
                actionButtons(title: "Compress") {
                    let mb = Double(targetMB.trimmingCharacters(in: .whitespaces)) ?? 5
                    let safeMB = mb.isFinite ? min(max(mb, 0.01), 1_000_000) : 5 // 10 KB to 1 TB
                    let target: CompressionTarget = compressBy == .percent
                        ? .percent(percent / 100)
                        : .bytes(Int64(safeMB * 1_000_000))
                    let plan = queue.jobs.filter { $0.kind.canCompress }.map { ($0.id, JobOperation.compress(target)) }
                    queue.start(plan, options: .fromDefaults(), reveal: revealWhenDone)
                }
            }
            Text("Works on images, video, audio and PDFs; other files are skipped. Originals are never changed.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var toolsControls: some View {
        let pdfs = queue.jobs.filter { $0.kind == .pdf }.map(\.id)
        let images = queue.jobs.filter { $0.kind == .image }.map(\.id)
        let cleanable = queue.jobs.filter { $0.kind.canStripMetadata }.map(\.id)
        let videos = queue.jobs.filter { $0.kind == .video }.map(\.id)
        let all = queue.jobs.map(\.id)
        let busy = queue.isRunning
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button("Merge PDFs") { queue.runBatch(.mergePDFs, ids: pdfs, options: .fromDefaults(), reveal: revealWhenDone) }
                    .disabled(pdfs.count < 2 || busy)
                Button("Images → PDF") { queue.runBatch(.imagesToPDF, ids: images, options: .fromDefaults(), reveal: revealWhenDone) }
                    .disabled(images.isEmpty || busy)
                Button("Split PDF Pages") {
                    queue.start(pdfs.map { ($0, JobOperation.splitPDF) }, options: .fromDefaults(), reveal: revealWhenDone)
                }
                .disabled(pdfs.isEmpty || busy)
                Button("Join Videos") { queue.runBatch(.joinVideos, ids: videos, options: .fromDefaults(), reveal: revealWhenDone) }
                    .disabled(videos.count < 2 || busy)
                    .help("Joins the videos in list order into one MP4")
            }
            HStack {
                Button("Zip All") { queue.runBatch(.archive(.zip), ids: all, options: .fromDefaults(), reveal: revealWhenDone) }
                    .disabled(all.isEmpty || busy)
                Button("Remove Metadata") {
                    queue.start(cleanable.map { ($0, JobOperation.stripMetadata) }, options: .fromDefaults(), reveal: revealWhenDone)
                }
                .disabled(cleanable.isEmpty || busy)
                Button("Read QR Codes") {
                    queue.start(images.map { ($0, JobOperation.readQR) }, options: .fromDefaults(), reveal: false)
                }
                .disabled(images.isEmpty || busy)
                Button("Float Files") { FloatingShelf.shared.add(queue.jobs.map(\.url)) }
                    .disabled(all.isEmpty)
                    .help("Keeps the files on a small always-on-top shelf you can drag them out of")
                Spacer()
                if busy { Button("Cancel") { queue.cancelAll() } }
            }
        }
    }

    @ViewBuilder
    private func actionButtons(title: String, action: @escaping () -> Void) -> some View {
        if queue.isRunning {
            Button("Cancel") { queue.cancelAll() }
        }
        Button(action: action) {
            Text(title).frame(minWidth: 80)
        }
        .buttonStyle(.borderedProminent)
        .keyboardShortcut(.defaultAction)
        .disabled(queue.jobs.isEmpty || queue.isRunning)
    }
}

/// Which editor sheet is open, and for which file.
struct EditRequest: Identifiable {
    enum Mode { case image, video, audio, info }

    let id = UUID()
    let jobID: UUID
    let url: URL
    let mode: Mode

    init(job: Job, mode: Mode) {
        jobID = job.id
        url = job.url
        self.mode = mode
    }

    static func editMode(for kind: FileKind) -> Mode? {
        switch kind {
        case .image: .image
        case .video: .video
        case .audio: .audio
        default: nil
        }
    }

    static func hasInfo(_ kind: FileKind) -> Bool {
        [.image, .video, .audio, .pdf].contains(kind)
    }
}

struct JobRow: View {
    let job: Job
    var onEdit: (() -> Void)?
    var onInfo: (() -> Void)?
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: job.url.path))
                .resizable()
                .frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(job.url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                Text("\(job.kind.title) · \(job.size.formattedSize)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if case .done(let result) = job.state, let message = result.message {
                    Text(message).font(.caption).textSelection(.enabled).lineLimit(3)
                }
                if case .failed(let message) = job.state {
                    Text(message).font(.caption).foregroundStyle(.red).textSelection(.enabled).lineLimit(3)
                }
            }
            Spacer()
            status
            if let onEdit {
                Button("Edit…", action: onEdit)
                    .disabled(isRunning)
                    .help("Open in the editor; the result is saved as a copy")
            }
            if let onInfo {
                Button(action: onInfo) { Image(systemName: "info.circle") }
                    .buttonStyle(.borderless)
                    .disabled(isRunning)
                    .help("View and edit metadata")
            }
            Button(action: onRemove) { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Remove from list")
        }
        .padding(.vertical, 2)
    }

    private var isRunning: Bool {
        if case .running = job.state { return true }
        return false
    }

    @ViewBuilder
    private var status: some View {
        switch job.state {
        case .queued:
            Text("Ready").font(.caption).foregroundStyle(.secondary)
        case .running(let fraction):
            ProgressView(value: fraction).frame(width: 100)
        case .done(let result):
            if !result.outputs.isEmpty {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting(result.outputs)
                } label: {
                    Label("Show", systemImage: "magnifyingglass")
                }
                .buttonStyle(.borderless)
            }
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
    }
}
