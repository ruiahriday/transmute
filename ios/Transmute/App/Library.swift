import Foundation
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Where the app keeps files. iPhone and iPad apps can't write next to the originals, so files are
/// copied in before converting, and results go to Documents/Converted, which the Files app shows as
/// On My iPhone › Transmute › Converted.
@MainActor
final class Library: ObservableObject {
    static let shared = Library()

    /// Shown as an alert when something couldn't be added.
    @Published var problem: String?
    /// Bumped whenever the Converted folder changes, so the saved-files list refreshes.
    @Published private(set) var outputsChanged = 0

    nonisolated static var outputFolder: URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let folder = documents.appendingPathComponent("Converted", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    nonisolated static var importsFolder: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("Imports", isDirectory: true)
    }

    /// A fresh place for an imported file that keeps its name.
    nonisolated static func newImportURL(named name: String) -> URL {
        let folder = importsFolder.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let clean = name.replacingOccurrences(of: "/", with: "-")
        return folder.appendingPathComponent(clean.isEmpty ? "File" : clean)
    }

    /// Conversion settings, with results always going to the Converted folder.
    var options: ConversionOptions {
        var options = ConversionOptions.fromDefaults()
        options.outputFolder = Self.outputFolder
        return options
    }

    func noteOutputsChanged() { outputsChanged += 1 }

    // MARK: Adding files

    /// Copies files picked in the Files app (or shared to Transmute) and adds them to the list.
    func add(_ urls: [URL]) {
        var local: [URL] = []
        var failures: [String] = []
        for url in urls {
            do {
                local.append(try Self.copyIn(url))
            } catch {
                failures.append(url.lastPathComponent)
            }
        }
        if !local.isEmpty { JobQueue.shared.add(local) }
        if !failures.isEmpty { problem = "Couldn't open \(failures.joined(separator: ", "))." }
    }

    /// Adds a file another app handed over. Files shared with "Copy to Transmute" arrive in
    /// Documents/Inbox, which is emptied once they're copied.
    func open(_ url: URL) {
        add([url])
        let inbox = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Inbox", isDirectory: true)
        if url.standardizedFileURL.path.hasPrefix(inbox.standardizedFileURL.path) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Reads a file through the system's file coordinator, so iCloud Drive files download first.
    nonisolated static func copyIn(_ url: URL) throws -> URL {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let target = newImportURL(named: url.lastPathComponent)
        var coordinationError: NSError?
        var copyError: Error?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [.withoutChanges], error: &coordinationError) { readable in
            do { try FileManager.default.copyItem(at: readable, to: target) } catch { copyError = error }
        }
        if let error = coordinationError ?? copyError { throw error }
        return target
    }

    /// Adds whatever is on the clipboard: files, photos, or text as a .txt file.
    func paste() {
        let providers = UIPasteboard.general.itemProviders
        guard !providers.isEmpty else {
            problem = "There's nothing to paste. Copy a photo, video or file first."
            return
        }
        for provider in providers {
            loadFile(from: provider)
        }
    }

    /// Takes the most specific file type a provider offers.
    func loadFile(from provider: NSItemProvider) {
        let types = provider.registeredTypeIdentifiers.compactMap(UTType.init)
        if let fileType = types.first(where: { !$0.conforms(to: .text) || $0.conforms(to: .rtf) || $0.conforms(to: .html) }) {
            provider.loadFileRepresentation(forTypeIdentifier: fileType.identifier) { url, _ in
                guard let url else { return }
                var name = provider.suggestedName ?? url.deletingPathExtension().lastPathComponent
                if let ext = fileType.preferredFilenameExtension ?? Optional(url.pathExtension), !ext.isEmpty,
                   (name as NSString).pathExtension.isEmpty {
                    name += ".\(ext)"
                }
                let target = Library.newImportURL(named: name)
                do {
                    try FileManager.default.copyItem(at: url, to: target)
                    Task { @MainActor in JobQueue.shared.add([target]) }
                } catch {
                    Task { @MainActor in Library.shared.problem = "Couldn't paste \(name)." }
                }
            }
        } else if provider.canLoadObject(ofClass: String.self) {
            _ = provider.loadObject(ofClass: String.self) { text, _ in
                guard let text else { return }
                let target = Library.newImportURL(named: "Pasted Text.txt")
                do {
                    try text.write(to: target, atomically: true, encoding: .utf8)
                    Task { @MainActor in JobQueue.shared.add([target]) }
                } catch {
                    Task { @MainActor in Library.shared.problem = "Couldn't paste the text." }
                }
            }
        }
    }

    /// Removes copies of files no longer in the list.
    func clear() {
        JobQueue.shared.clear()
        let kept = Set(JobQueue.shared.jobs.map { $0.url.deletingLastPathComponent().standardizedFileURL.path })
        let folders = (try? FileManager.default.contentsOfDirectory(at: Self.importsFolder, includingPropertiesForKeys: nil)) ?? []
        for folder in folders where !kept.contains(folder.standardizedFileURL.path) {
            try? FileManager.default.removeItem(at: folder)
        }
    }

    // MARK: Converted files

    func savedFiles() -> [URL] {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        let files = (try? FileManager.default.contentsOfDirectory(at: Self.outputFolder, includingPropertiesForKeys: keys,
                                                                    options: [.skipsHiddenFiles])) ?? []
        func date(_ url: URL) -> Date {
            (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        }
        return files.sorted { date($0) > date($1) }
    }

    func delete(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
        noteOutputsChanged()
    }
}

/// A photo or video from the photo library, copied out as a file with its original format.
struct PickedMedia: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .movie) { received in
            PickedMedia(url: try copy(received.file))
        }
        FileRepresentation(importedContentType: .image) { received in
            PickedMedia(url: try copy(received.file))
        }
    }

    private static func copy(_ file: URL) throws -> URL {
        let target = Library.newImportURL(named: file.lastPathComponent)
        try FileManager.default.copyItem(at: file, to: target)
        return target
    }
}
