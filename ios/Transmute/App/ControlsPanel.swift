import SwiftUI

/// The bottom panel: what to do with the files in the list.
struct ControlsPanel: View {
    @EnvironmentObject private var queue: JobQueue
    @EnvironmentObject private var library: Library
    let onEditRequest: (MobileEditRequest) -> Void

    @State private var mode: Mode = .convert
    @State private var choices: [FileKind: OutputFormat] = [:]
    @State private var compressBy: CompressBy = .percent
    @State private var percent = 50.0
    @State private var targetMB = "5"
    @FocusState private var sizeFieldFocused: Bool

    enum Mode: String, CaseIterable, Identifiable {
        case convert = "Convert", compress = "Compress", tools = "Tools"
        var id: String { rawValue }
    }

    enum CompressBy { case percent, size }

    var body: some View {
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
        .padding(16)
        .frame(maxWidth: 700)
        .frame(maxWidth: .infinity)
        .background(.regularMaterial)
        .overlay(alignment: .top) { Divider() }
        .onReceive(Automation.shared.$screen) { screen in
            if let screen, let chosen = Mode(rawValue: screen.capitalized) { mode = chosen }
        }
    }

    // MARK: Convert

    /// Formats offered for each kind of file in the list: those every file of that kind can make.
    private func targets(for kind: FileKind) -> [OutputFormat] {
        let files = queue.jobs.filter { $0.kind == kind }
        guard let first = files.first else { return [] }
        var common = Mobile.targets(for: first.url)
        for job in files.dropFirst() {
            let these = Set(Mobile.targets(for: job.url))
            common = common.filter(these.contains)
        }
        return common
    }

    private var convertControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(queue.kindsPresent) { kind in
                let options = targets(for: kind)
                HStack {
                    Label(kind.title, systemImage: kind.symbol)
                    Spacer()
                    if options.isEmpty {
                        Text("Not on iPhone yet").foregroundStyle(.secondary)
                    } else {
                        Picker(kind.title, selection: format(for: kind, options)) {
                            ForEach(options) { Text($0.label).tag($0) }
                        }
                        .pickerStyle(.menu)
                    }
                }
            }
            actionButton("Convert") {
                let plan = queue.jobs.compactMap { job -> (UUID, JobOperation)? in
                    let options = targets(for: job.kind)
                    guard let first = options.first else { return nil }
                    let chosen = choices[job.kind].flatMap { options.contains($0) ? $0 : nil } ?? first
                    return (job.id, .convert(chosen))
                }
                queue.start(plan, options: library.options, reveal: false)
            }
        }
    }

    private func format(for kind: FileKind, _ options: [OutputFormat]) -> Binding<OutputFormat> {
        Binding(get: { choices[kind].flatMap { options.contains($0) ? $0 : nil } ?? options[0] },
                set: { choices[kind] = $0 })
    }

    // MARK: Compress

    private var compressControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Compress by", selection: $compressBy) {
                Text("Percentage").tag(CompressBy.percent)
                Text("Target size").tag(CompressBy.size)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            if compressBy == .percent {
                HStack {
                    Slider(value: $percent, in: 10...90, step: 5)
                    Text("\(Int(percent))%").monospacedDigit().frame(width: 48, alignment: .trailing)
                }
                Text("Each file shrinks to about \(Int(percent))% of its size.").font(.caption).foregroundStyle(.secondary)
            } else {
                HStack {
                    TextField("MB", text: $targetMB)
                        .keyboardType(.decimalPad)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 90)
                        .focused($sizeFieldFocused)
                    Text("MB per file")
                    Spacer()
                }
            }
            actionButton("Compress") {
                sizeFieldFocused = false
                let mb = Double(targetMB.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")) ?? 5
                let safeMB = mb.isFinite ? min(max(mb, 0.01), 1_000_000) : 5
                let target: CompressionTarget = compressBy == .percent ? .percent(percent / 100) : .bytes(Int64(safeMB * 1_000_000))
                let plan = queue.jobs.filter { Mobile.canCompress($0.url) }.map { ($0.id, JobOperation.compress(target)) }
                queue.start(plan, options: library.options, reveal: false)
            }
            .disabled(!queue.jobs.contains { Mobile.canCompress($0.url) })
            Text("Works on images, video, audio and PDFs. Originals are never changed.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Tools

    private var toolsControls: some View {
        let pdfs = queue.jobs.filter { $0.kind == .pdf }.map(\.id)
        let images = queue.jobs.filter { $0.kind == .image && Mobile.canOpen($0.url) }.map(\.id)
        let videos = queue.jobs.filter { $0.kind == .video && Mobile.canOpen($0.url) }.map(\.id)
        let cleanable = queue.jobs.filter { Mobile.canStripMetadata($0.url) }.map(\.id)
        let all = queue.jobs.map(\.id)
        let busy = queue.isRunning
        let options = library.options
        return VStack(spacing: 8) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 8)], spacing: 8) {
                tool("Merge PDFs", "doc.on.doc", disabled: pdfs.count < 2 || busy) {
                    queue.runBatch(.mergePDFs, ids: pdfs, options: options, reveal: false)
                }
                tool("Images → PDF", "doc.richtext", disabled: images.isEmpty || busy) {
                    queue.runBatch(.imagesToPDF, ids: images, options: options, reveal: false)
                }
                tool("Split PDF Pages", "scissors", disabled: pdfs.isEmpty || busy) {
                    queue.start(pdfs.map { ($0, JobOperation.splitPDF) }, options: options, reveal: false)
                }
                tool("Join Videos", "film.stack", disabled: videos.count < 2 || busy) {
                    queue.runBatch(.joinVideos, ids: videos, options: options, reveal: false)
                }
                tool("Zip All", "archivebox", disabled: all.isEmpty || busy) {
                    queue.runBatch(.archive(.zip), ids: all, options: options, reveal: false)
                }
                tool("Remove Metadata", "eye.slash", disabled: cleanable.isEmpty || busy) {
                    queue.start(cleanable.map { ($0, JobOperation.stripMetadata) }, options: options, reveal: false)
                }
                tool("Read QR Codes", "qrcode.viewfinder", disabled: images.isEmpty || busy) {
                    queue.start(images.map { ($0, JobOperation.readQR) }, options: options, reveal: false)
                }
            }
            if busy {
                Button("Cancel", role: .destructive) { queue.cancelAll() }
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private func tool(_ title: String, _ symbol: String, disabled: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.subheadline)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.bordered)
        .disabled(disabled)
    }

    @ViewBuilder
    private func actionButton(_ title: String, action: @escaping () -> Void) -> some View {
        HStack {
            if queue.isRunning {
                Button("Cancel", role: .destructive) { queue.cancelAll() }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
            }
            Button(action: action) {
                Text(title).frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(queue.jobs.isEmpty || queue.isRunning)
        }
    }
}
