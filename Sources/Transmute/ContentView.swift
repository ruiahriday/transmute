import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject private var queue: JobQueue

    @AppStorage(Prefs.imageQuality) private var quality = 0.85
    @AppStorage(Prefs.stripMetadata) private var stripMetadata = false
    @AppStorage(Prefs.revealWhenDone) private var revealWhenDone = true

    @State private var mode: Mode = .convert
    @State private var area: Area = .files
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

    /// The two halves of the window: files to convert, and the screen capture tools.
    enum Area: String, CaseIterable, Identifiable {
        case files = "Files", capture = "Capture"
        var id: String { rawValue }
        var symbol: String { self == .files ? "doc.on.doc" : "camera.viewfinder" }
    }

    /// `initialMode` picks the tab shown first (the window pictures show the Tools tab too).
    init(initialMode: Mode = .convert, initialArea: Area = .files) {
        _mode = State(initialValue: initialMode)
        _area = State(initialValue: initialArea)
    }

    var body: some View {
        ZStack {
            AppBackground()
            VStack(spacing: 12) {
                header.layoutPriority(1)
                if area == .capture {
                    CaptureHomeView()
                        .frame(maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                        .transition(.opacity)
                } else {
                    Group {
                        if queue.jobs.isEmpty {
                            emptyState.transition(.opacity.combined(with: .scale(scale: 0.97)))
                        } else {
                            fileList.transition(.opacity)
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                    controls.crispCard(padding: 14).layoutPriority(1)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
            .padding(.top, 4)
            .animation(Theme.spring, value: queue.jobs.isEmpty)
            .animation(Theme.spring, value: area)
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
        .tint(Theme.accent)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            SpinformMark()
                .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 0) {
                Text("Spinform")
                    .font(Theme.Fonts.wordmark)
                    .foregroundStyle(Theme.brandText)
                Text(area == .capture ? "Capture. Mark up. Share." : "Drop. Pick a format. Done.")
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer()
            if !queue.jobs.isEmpty && area == .files {
                summaryChip.transition(.scale.combined(with: .opacity))
            }
            SlidingPicker(options: Area.allCases, selection: $area, title: \.rawValue, symbol: \.symbol)
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
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(done == total ? Theme.success : Theme.accentText)
            }
            Text(done > 0 ? "\(done) of \(total) done" : "\(total) file\(total == 1 ? "" : "s")")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
                .monospacedDigit()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous).strokeBorder(Theme.hairline))
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
        .crispCard(padding: 0)
    }

    private var fileList: some View {
        ScrollView {
            LazyVStack(spacing: 6) {
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
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .strokeBorder(Theme.brand, lineWidth: 2)
                    .background(Theme.violet.opacity(0.06), in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
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
                Text("Add some files to choose output formats.").font(Theme.Fonts.body).foregroundStyle(Theme.textSecondary)
            }
            ForEach(queue.kindsPresent) { kind in
                Picker(selection: format(for: kind)) {
                    ForEach(kind.convertTargets) { Text($0.label).tag($0) }
                } label: {
                    Label(kind.title, systemImage: kind.symbol)
                        .font(Theme.Fonts.body)
                        .foregroundStyle(Theme.textPrimary)
                        .frame(width: 120, alignment: .leading)
                }
                .frame(maxWidth: 320)
            }
            HStack(spacing: 12) {
                if queue.kindsPresent.contains(.image) || queue.kindsPresent.contains(.pdf) {
                    Text("Quality").font(Theme.Fonts.body).foregroundStyle(Theme.textPrimary)
                    Slider(value: $quality, in: 0.1...1).frame(width: 140)
                    Text("\(Int(quality * 100))%").font(Theme.Fonts.body).monospacedDigit()
                        .foregroundStyle(Theme.textSecondary).frame(width: 40, alignment: .leading)
                }
                Toggle("Remove metadata", isOn: $stripMetadata)
                    .toggleStyle(CrispCheckboxStyle())
                    .help("Leaves out location, camera and other details from the converted copies")
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
                    Text("to \(Int(percent))% of original").font(Theme.Fonts.body).monospacedDigit()
                } else {
                    TextField("MB", text: $targetMB).frame(width: 60)
                    Text("MB per file").font(Theme.Fonts.body)
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
                .font(Theme.Fonts.caption)
                .foregroundStyle(Theme.textSecondary)
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
            HStack(spacing: 6) {
                Button { runBackground(.remove, on: images) } label: { Label("Remove Background", systemImage: "scissors") }
                    .disabled(images.isEmpty || busy)
                    .help("Cuts out the main subject of every image and saves transparent PNGs")
                Menu {
                    Button("White") { runBackground(BackgroundEdit(fill: .color(.white)), on: images) }
                    Button("Light Grey") { runBackground(BackgroundEdit(fill: .color(RGBAColor(hex: 0xF1F1F4))), on: images) }
                    Button("Black") { runBackground(BackgroundEdit(fill: .color(RGBAColor(hex: 0x18181B))), on: images) }
                    Divider()
                    ForEach(GradientPreset.all) { preset in
                        Button("\(preset.name) Gradient") { runBackground(BackgroundEdit(fill: preset.fill), on: images) }
                    }
                    Divider()
                    Button("Blur the Original") { runBackground(BackgroundEdit(fill: .blur(0.5)), on: images) }
                    Button("A Picture…") { chooseBackgroundPicture(for: images) }
                } label: {
                    Label("New Background", systemImage: "photo.on.rectangle")
                }
                .menuStyle(.borderlessButton)
                .tint(Theme.textPrimary)
                .fixedSize()
                .padding(.horizontal, 10)
                .padding(.vertical, 3)
                .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous).strokeBorder(Theme.hairline))
                .disabled(images.isEmpty || busy)
                .help("Keeps the subject and puts a colour, gradient, blur or picture behind it; for every image")
                Button("Images → PDF") { queue.runBatch(.imagesToPDF, ids: images, options: .fromDefaults(), reveal: revealWhenDone) }
                    .disabled(images.isEmpty || busy)
                Button("Read QR Codes") {
                    queue.start(images.map { ($0, JobOperation.readQR) }, options: .fromDefaults(), reveal: false)
                }
                .disabled(images.isEmpty || busy)
            }
            HStack(spacing: 6) {
                Button("Merge PDFs") { queue.runBatch(.mergePDFs, ids: pdfs, options: .fromDefaults(), reveal: revealWhenDone) }
                    .disabled(pdfs.count < 2 || busy)
                Button("Split PDF Pages") {
                    queue.start(pdfs.map { ($0, JobOperation.splitPDF) }, options: .fromDefaults(), reveal: revealWhenDone)
                }
                .disabled(pdfs.isEmpty || busy)
                Button("Join Videos") { queue.runBatch(.joinVideos, ids: videos, options: .fromDefaults(), reveal: revealWhenDone) }
                    .disabled(videos.count < 2 || busy)
                    .help("Joins the videos in list order into one MP4")
            }
            HStack(spacing: 6) {
                Button("Zip All") { queue.runBatch(.archive(.zip), ids: all, options: .fromDefaults(), reveal: revealWhenDone) }
                    .disabled(all.isEmpty || busy)
                Button("Remove Metadata") {
                    queue.start(cleanable.map { ($0, JobOperation.stripMetadata) }, options: .fromDefaults(), reveal: revealWhenDone)
                }
                .disabled(cleanable.isEmpty || busy)
                Button("Float Files") { FloatingShelf.shared.add(queue.jobs.map(\.url)) }
                    .disabled(all.isEmpty)
                    .help("Keeps the files on a small always-on-top shelf you can drag them out of")
                Spacer()
                if busy { Button("Cancel") { queue.cancelAll() } }
            }
        }
    }

    /// Remove or replace the background of every image in the list, two at a time.
    private func runBackground(_ background: BackgroundEdit, on ids: [UUID]) {
        var edit = ImageEdit()
        edit.background = background
        queue.start(ids.map { ($0, JobOperation.editImage(edit)) }, options: .fromDefaults(), reveal: revealWhenDone)
    }

    private func chooseBackgroundPicture(for ids: [UUID]) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.prompt = "Use as Background"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        runBackground(BackgroundEdit(fill: .image(url)), on: ids)
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
        editor.tint(Theme.accent)
    }

    @ViewBuilder private var editor: some View {
        let id = request.jobID
        switch request.mode {
        case .image:
            ImageEditorView(url: request.url, startOnMarkup: request.startOnMarkup, onSave: { edit in
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
    /// Open the photo editor on its Markup tools (for screenshots).
    var startOnMarkup = false

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
            KindBadge(kind: job.kind, size: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(job.url.lastPathComponent)
                    .font(Theme.Fonts.bodyStrong)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("\(job.kind.title) · \(job.size.formattedSize)")
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Theme.textSecondary)
                if case .done(let result) = job.state, let message = result.message {
                    Text(message).font(Theme.Fonts.caption.weight(.medium)).foregroundStyle(Theme.success)
                        .textSelection(.enabled).lineLimit(3)
                }
                if case .failed(let message) = job.state {
                    Text(message).font(Theme.Fonts.caption.weight(.medium)).foregroundStyle(Theme.danger)
                        .textSelection(.enabled).lineLimit(3)
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
                Button(action: onInfo) {
                    Image(systemName: "info.circle").font(.system(size: 14, weight: .medium))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(Theme.accentText)
                .disabled(isRunning)
                .help("View and edit metadata")
            }
            Button(action: onRemove) {
                Image(systemName: "xmark").font(.system(size: 10, weight: .bold))
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(hovering ? Theme.surfaceHover : Color.clear))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(hovering ? Theme.textPrimary : Theme.textTertiary)
            .help("Remove from list")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
                .strokeBorder(hovering ? Theme.tint(job.kind).opacity(0.7) : Theme.hairline, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.04), radius: 1, y: 1)
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
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Theme.hairline))
        case .running(let fraction):
            HStack(spacing: 8) {
                GlowProgressBar(value: fraction, tint: Theme.tint(job.kind)).frame(width: 110)
                Text("\(Int(fraction * 100))%")
                    .font(Theme.Fonts.caption.monospacedDigit().weight(.medium))
                    .foregroundStyle(Theme.textSecondary)
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
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.warning)
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
