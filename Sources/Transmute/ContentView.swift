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
        var symbol: String {
            switch self {
            case .convert: "arrow.triangle.2.circlepath"
            case .compress: "arrow.down.right.and.arrow.up.left"
            case .tools: "wrench.and.screwdriver"
            }
        }
    }

    enum CompressBy { case percent, size }

    var body: some View {
        ZStack {
            AuroraBackground()
            VStack(spacing: 14) {
                header.layoutPriority(1)
                Group {
                    if queue.jobs.isEmpty {
                        emptyState.transition(.opacity.combined(with: .scale(scale: 0.97)))
                    } else {
                        fileList.transition(.opacity)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                controls.glassCard(radius: 20, padding: 16).layoutPriority(1)
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 18)
            .padding(.top, 6)
            .animation(Theme.spring, value: queue.jobs.isEmpty)
        }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            load(providers)
            return true
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { queue.add(urls) }
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
        .sheet(item: $editing) { request in EditorHost(request: request, close: { editing = nil }) }
        .frame(minWidth: 640, minHeight: 520)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 38, height: 38)
                .shadow(color: Theme.blue.opacity(0.35), radius: 8, y: 3)
            VStack(alignment: .leading, spacing: 1) {
                Text("Transmute")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.brand)
                Text("Drop. Pick a format. Done.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if !queue.jobs.isEmpty {
                summaryChip.transition(.scale.combined(with: .opacity))
            }
        }
    }

    private var summaryChip: some View {
        let done = queue.jobs.filter { if case .done = $0.state { return true } else { return false } }.count
        let total = queue.jobs.count
        return HStack(spacing: 6) {
            if queue.isRunning {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: done == total ? "checkmark.seal.fill" : "square.stack.3d.up.fill")
                    .foregroundStyle(done == total ? Theme.teal : Theme.blue)
            }
            Text(done > 0 ? "\(done) of \(total) done" : "\(total) file\(total == 1 ? "" : "s")")
                .font(.system(size: 12, weight: .semibold))
                .monospacedDigit()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08)))
        .animation(Theme.spring, value: done)
    }

    // MARK: File list

    private var emptyState: some View {
        DropHero(
            targeted: dropTargeted,
            wheelHint: WheelKind.convert.key == .off ? nil
                : "Tip: hold \(WheelKind.convert.key.label) while dragging a file anywhere to convert it on the spot",
            onChoose: { showImporter = true }
        )
        .glassCard(radius: 24, padding: 0)
    }

    private var fileList: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                ForEach(queue.jobs) { job in
                    JobRow(
                        job: job,
                        onEdit: editAction(for: job),
                        onInfo: infoAction(for: job),
                        onRemove: { withAnimation(Theme.spring) { queue.remove(job.id) } }
                    )
                    .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity),
                                            removal: .scale(scale: 0.9).combined(with: .opacity)))
                }
            }
            .padding(.vertical, 4)
            .animation(Theme.spring, value: queue.jobs.map(\.id))
        }
        .scrollContentBackground(.hidden)
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Theme.brand, lineWidth: 3)
                    .background(Theme.blue.opacity(0.06), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.2), value: dropTargeted)
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

    private func editAction(for job: Job) -> (() -> Void)? {
        guard let mode = EditRequest.editMode(for: job.kind) else { return nil }
        return { editing = EditRequest(job: job, mode: mode) }
    }

    private func infoAction(for job: Job) -> (() -> Void)? {
        guard EditRequest.hasInfo(job.kind) else { return nil }
        return { editing = EditRequest(job: job, mode: .info) }
    }

    // MARK: Controls

    private var controls: some View {
        VStack(alignment: .leading, spacing: 12) {
            SlidingPicker(options: Mode.allCases, selection: $mode, title: \.rawValue, symbol: \.symbol)

            Group {
                switch mode {
                case .convert: convertControls
                case .compress: compressControls
                case .tools: toolsControls.buttonStyle(ChipButtonStyle())
                }
            }
            .transition(.opacity.combined(with: .move(edge: .bottom)))
            .id(mode)
        }
        .animation(Theme.spring, value: mode)
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
                .buttonStyle(ChipButtonStyle())
        }
        Button(action: action) {
            Label(title, systemImage: "sparkles").frame(minWidth: 90)
        }
        .buttonStyle(GlowButtonStyle())
        .keyboardShortcut(.defaultAction)
        .disabled(queue.jobs.isEmpty || queue.isRunning)
    }
}

/// The photo, video, audio or info editor for one file, shown as a sheet in the main window or
/// in its own window when opened from the drag wheel.
struct EditorHost: View {
    let request: EditRequest
    let close: () -> Void

    var body: some View {
        let id = request.jobID
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

    private func run(_ id: UUID, _ operation: JobOperation) {
        JobQueue.shared.start([(id, operation)], options: .fromDefaults(),
                              reveal: UserDefaults.standard.bool(forKey: Prefs.revealWhenDone))
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

    @State private var hovering = false
    @State private var shake = 0.0

    var body: some View {
        HStack(spacing: 12) {
            KindBadge(kind: job.kind)
            VStack(alignment: .leading, spacing: 3) {
                Text(job.url.lastPathComponent)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("\(job.kind.title) · \(job.size.formattedSize)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if case .done(let result) = job.state, let message = result.message {
                    Text(message).font(.caption).foregroundStyle(Theme.teal).textSelection(.enabled).lineLimit(3)
                }
                if case .failed(let message) = job.state {
                    Text(message).font(.caption).foregroundStyle(.red).textSelection(.enabled).lineLimit(3)
                }
            }
            Spacer(minLength: 8)
            status
            if let onEdit {
                Button(action: onEdit) { Label("Edit", systemImage: "wand.and.stars") }
                    .buttonStyle(ChipButtonStyle())
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
                .opacity(hovering ? 1 : 0.5)
                .help("Remove from list")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(hovering ? Theme.tint(job.kind).opacity(0.6) : Color.primary.opacity(0.07), lineWidth: 1)
        )
        .shadow(color: .black.opacity(hovering ? 0.14 : 0.06), radius: hovering ? 12 : 6, y: hovering ? 6 : 3)
        .scaleEffect(hovering ? 1.008 : 1)
        .modifier(Shake(amount: shake))
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.18), value: hovering)
        .onChange(of: job.state.isFailed) { failed in
            if failed { withAnimation(.linear(duration: 0.4)) { shake += 1 } }
        }
    }

    private var isRunning: Bool {
        if case .running = job.state { return true }
        return false
    }

    @ViewBuilder
    private var status: some View {
        switch job.state {
        case .queued:
            Text("Ready")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(Color.primary.opacity(0.06)))
        case .running(let fraction):
            HStack(spacing: 8) {
                GlowProgressBar(value: fraction, tint: Theme.tint(job.kind)).frame(width: 110)
                Text("\(Int(fraction * 100))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 34, alignment: .trailing)
            }
        case .done(let result):
            HStack(spacing: 8) {
                if !result.outputs.isEmpty {
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting(result.outputs)
                    } label: {
                        Label("Show", systemImage: "magnifyingglass")
                    }
                    .buttonStyle(ChipButtonStyle())
                }
                PopCheck()
            }
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
    }
}

/// Shakes a view sideways once each time `amount` goes up by one.
struct Shake: GeometryEffect {
    var amount: Double
    var animatableData: Double {
        get { amount }
        set { amount = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: 6 * sin(amount * .pi * 6), y: 0))
    }
}
