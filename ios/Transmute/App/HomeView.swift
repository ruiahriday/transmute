import PhotosUI
import QuickLook
import QuickLookThumbnailing
import SwiftUI
import UniformTypeIdentifiers

struct HomeView: View {
    @EnvironmentObject private var queue: JobQueue
    @EnvironmentObject private var library: Library

    @State private var showFiles = false
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var showPhotos = false
    @State private var showSettings = false
    @State private var showSaved = false
    @State private var editing: MobileEditRequest?
    @State private var preview: URL?

    var body: some View {
        NavigationStack {
            Group {
                if queue.jobs.isEmpty {
                    EmptyStateView(chooseFiles: { showFiles = true }, choosePhotos: { showPhotos = true },
                                   paste: { library.paste() })
                } else {
                    fileList
                }
            }
            .navigationTitle("Transmute")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button { showSettings = true } label: { Label("Settings", systemImage: "gearshape") }
                }
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    Button { showSaved = true } label: { Label("Converted Files", systemImage: "folder") }
                    addMenu
                }
            }
            .safeAreaInset(edge: .bottom) {
                if !queue.jobs.isEmpty {
                    ControlsPanel(onEditRequest: { editing = $0 })
                }
            }
        }
        .fileImporter(isPresented: $showFiles, allowedContentTypes: [.item, .folder], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): library.add(urls)
            case .failure(let error): library.problem = error.localizedDescription
            }
        }
        .photosPicker(isPresented: $showPhotos, selection: $photoItems, maxSelectionCount: 50,
                      matching: .any(of: [.images, .videos]), preferredItemEncoding: .current)
        .onChange(of: photoItems) { items in
            guard !items.isEmpty else { return }
            photoItems = []
            Task { await importPhotos(items) }
        }
        .sheet(isPresented: $showSettings) { SettingsSheet() }
        .sheet(isPresented: $showSaved) { SavedFilesView() }
        .fullScreenCover(item: $editing) { request in
            EditorHost(request: request) { editing = nil }
        }
        .quickLookPreview($preview)
        .alert("Transmute", isPresented: Binding(get: { library.problem != nil }, set: { if !$0 { library.problem = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(library.problem ?? "")
        }
        .onChange(of: queue.isRunning) { running in
            if !running { library.noteOutputsChanged() }
        }
        .onReceive(Automation.shared.$screen) { screen in
            guard let screen, let job = queue.jobs.first else {
                if screen == "settings" { showSettings = true }
                return
            }
            switch screen {
            case "settings": showSettings = true
            case "saved": showSaved = true
            case "image": editing = MobileEditRequest(job: job, kind: .image)
            case "video": editing = MobileEditRequest(job: job, kind: .video)
            case "audio": editing = MobileEditRequest(job: job, kind: .audio)
            case "info": editing = MobileEditRequest(job: job, kind: .info)
            default: break
            }
        }
    }

    private var addMenu: some View {
        Menu {
            Button { showFiles = true } label: { Label("Choose Files", systemImage: "folder") }
            Button { showPhotos = true } label: { Label("Choose Photos or Videos", systemImage: "photo.on.rectangle") }
            Button { library.paste() } label: { Label("Paste", systemImage: "doc.on.clipboard") }
        } label: {
            Label("Add Files", systemImage: "plus")
        }
    }

    private var fileList: some View {
        List {
            ForEach(queue.jobs) { job in
                JobCard(job: job,
                        onEdit: editAction(for: job),
                        onInfo: infoAction(for: job),
                        onPreview: { preview = $0 })
                    .swipeActions {
                        Button(role: .destructive) { queue.remove(job.id) } label: { Label("Remove", systemImage: "trash") }
                    }
            }
            Section {
                Button(role: .destructive) { library.clear() } label: {
                    Label("Clear List", systemImage: "xmark.circle")
                }
                .disabled(queue.isRunning)
            }
        }
        .listStyle(.insetGrouped)
    }

    private func editAction(for job: Job) -> (() -> Void)? {
        guard let editor = Mobile.editor(for: job.url) else { return nil }
        return { editing = MobileEditRequest(job: job, editor: editor) }
    }

    private func infoAction(for job: Job) -> (() -> Void)? {
        guard Mobile.hasInfo(job.url) else { return nil }
        return { editing = MobileEditRequest(job: job, kind: .info) }
    }

    private func importPhotos(_ items: [PhotosPickerItem]) async {
        var failed = 0
        for item in items {
            do {
                if let media = try await item.loadTransferable(type: PickedMedia.self) {
                    queue.add([media.url])
                } else {
                    failed += 1
                }
            } catch {
                failed += 1
            }
        }
        if failed > 0 { library.problem = "\(failed) item\(failed == 1 ? "" : "s") couldn't be loaded from Photos." }
    }
}

// MARK: - Empty state

struct EmptyStateView: View {
    let chooseFiles: () -> Void
    let choosePhotos: () -> Void
    let paste: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(.tint)
                    .padding(.top, 32)
                Text("Convert anything")
                    .font(.title2.weight(.semibold))
                Text("Images, video, audio, PDFs, Word documents, e-books, spreadsheets, subtitles and zip files")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                VStack(spacing: 10) {
                    bigButton("Choose Files", "folder", chooseFiles)
                    bigButton("Choose Photos or Videos", "photo.on.rectangle", choosePhotos)
                    bigButton("Paste", "doc.on.clipboard", paste)
                }
                .padding(.top, 8)
                Label("You can also send files here from other apps: tap Share, then Transmute.",
                      systemImage: "square.and.arrow.up")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.top, 8)
            }
            .padding(24)
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
        }
    }

    private func bigButton(_ title: String, _ symbol: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
    }
}

// MARK: - One file in the list

struct JobCard: View {
    let job: Job
    var onEdit: (() -> Void)?
    var onInfo: (() -> Void)?
    let onPreview: (URL) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Thumbnail(url: job.url, size: 46)
                    .onTapGesture { onPreview(job.url) }
                VStack(alignment: .leading, spacing: 2) {
                    Text(job.url.lastPathComponent)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text("\(job.kind.title) · \(job.size.formattedSize)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                status
                if onEdit != nil || onInfo != nil {
                    Menu {
                        if let onEdit { Button(action: onEdit) { Label("Edit…", systemImage: "slider.horizontal.3") } }
                        if let onInfo { Button(action: onInfo) { Label("Info and Tags…", systemImage: "info.circle") } }
                        Button { onPreview(job.url) } label: { Label("Preview", systemImage: "eye") }
                    } label: {
                        Image(systemName: "ellipsis.circle").font(.title3)
                    }
                    .disabled(isRunning)
                }
            }
            if case .running(let fraction) = job.state {
                ProgressView(value: fraction)
            }
            if case .done(let result) = job.state {
                if let message = result.message {
                    Text(message).font(.caption).textSelection(.enabled)
                }
                ForEach(result.outputs, id: \.self) { output in
                    OutputRow(url: output, onPreview: onPreview)
                }
            }
            if case .failed(let message) = job.state {
                Text(message).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
        }
        .padding(.vertical, 4)
    }

    private var isRunning: Bool {
        if case .running = job.state { return true }
        return false
    }

    @ViewBuilder
    private var status: some View {
        switch job.state {
        case .queued: EmptyView()
        case .running: ProgressView()
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
    }
}

/// A finished file: tap to look at it, or share it (which includes Save to Files and Save to Photos).
struct OutputRow: View {
    let url: URL
    let onPreview: (URL) -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: isFolder ? "folder.fill" : "doc.fill")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(url.lastPathComponent).font(.subheadline).lineLimit(1).truncationMode(.middle)
                if !isFolder {
                    Text(OutputPaths.fileSize(url).formattedSize).font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if !isFolder {
                Button { onPreview(url) } label: { Image(systemName: "eye") }
                    .buttonStyle(.borderless)
            }
            ShareLink(items: shareItems) { Image(systemName: "square.and.arrow.up") }
                .buttonStyle(.borderless)
        }
        .padding(8)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
    }

    private var isFolder: Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    /// A folder (split pages, extracted archives) is shared as the files inside it.
    private var shareItems: [URL] {
        guard isFolder else { return [url] }
        let files = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil,
                                                                   options: [.skipsHiddenFiles])) ?? []
        return files.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }
}

/// A Quick Look thumbnail, with the file kind's symbol until it's ready.
struct Thumbnail: View {
    let url: URL
    let size: CGFloat
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8).fill(Color(uiColor: .tertiarySystemFill))
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: FileKind.of(url).symbol).foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .task(id: url) {
            let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: size, height: size),
                                                       scale: UIScreen.main.scale, representationTypes: .thumbnail)
            image = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).uiImage
        }
    }
}
