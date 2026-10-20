import QuickLook
import SwiftUI

struct SettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var library: Library
    @AppStorage(Prefs.imageQuality) private var quality = 0.85
    @AppStorage(Prefs.stripMetadata) private var stripMetadata = false
    @State private var confirmClear = false

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "\(short) (build \(build))"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading) {
                        HStack {
                            Text("Image and PDF quality")
                            Spacer()
                            Text("\(Int(quality * 100))%").monospacedDigit().foregroundStyle(.secondary)
                        }
                        Slider(value: $quality, in: 0.1...1)
                    }
                    Toggle("Remove metadata when converting", isOn: $stripMetadata)
                } footer: {
                    Text("Removing metadata drops location, camera and author details from the converted copies.")
                }

                Section {
                    LabeledContent("Converted files", value: "Transmute › Converted")
                    if let files = filesAppURL {
                        Link(destination: files) { Label("Show in the Files App", systemImage: "folder") }
                    }
                    Button("Delete All Converted Files", role: .destructive) { confirmClear = true }
                } header: {
                    Text("Where files go")
                } footer: {
                    Text("Find them in the Files app under On My iPhone (or On My iPad) › Transmute. Originals are never changed.")
                }

                Section("About") {
                    LabeledContent("Version", value: version)
                    Link(destination: URL(string: "https://github.com/ruiahriday/transmute/issues/new?template=beta-feedback.yml")!) {
                        Label("Send Feedback", systemImage: "envelope")
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .confirmationDialog("Delete every converted file?", isPresented: $confirmClear, titleVisibility: .visible) {
                Button("Delete All", role: .destructive) {
                    for url in library.savedFiles() { library.delete(url) }
                }
            }
        }
    }

    /// The Files app opens a folder from a "shareddocuments://" link.
    private var filesAppURL: URL? {
        var components = URLComponents(url: Library.outputFolder, resolvingAgainstBaseURL: false)
        components?.scheme = "shareddocuments"
        return components?.url
    }
}

/// Everything in the Converted folder, newest first.
struct SavedFilesView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var library: Library
    @State private var files: [URL] = []
    @State private var preview: URL?

    var body: some View {
        NavigationStack {
            Group {
                if files.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "folder").font(.system(size: 44)).foregroundStyle(.secondary)
                        Text("Nothing converted yet").font(.headline)
                        Text("Converted files appear here and in the Files app under Transmute › Converted.")
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.secondary)
                    }
                    .padding(32)
                } else {
                    List {
                        ForEach(files, id: \.self) { url in
                            HStack(spacing: 12) {
                                Thumbnail(url: url, size: 40)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                                    Text(isFolder(url) ? "Folder" : OutputPaths.fileSize(url).formattedSize)
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                ShareLink(item: url) { Image(systemName: "square.and.arrow.up") }
                                    .buttonStyle(.borderless)
                            }
                            .contentShape(Rectangle())
                            .onTapGesture { if !isFolder(url) { preview = url } }
                        }
                        .onDelete { offsets in
                            for index in offsets { library.delete(files[index]) }
                        }
                    }
                }
            }
            .navigationTitle("Converted")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .quickLookPreview($preview)
            .onAppear { files = library.savedFiles() }
            .onChange(of: library.outputsChanged) { _ in files = library.savedFiles() }
        }
    }

    private func isFolder(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }
}
