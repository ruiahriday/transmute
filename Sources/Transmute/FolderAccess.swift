import AppKit
import Foundation

/// Where results may be saved.
///
/// The download build saves next to the original or in the folder from Settings, by path.
/// The App Store build runs in the App Sandbox, where the app may only write to places the
/// user handed it. There:
///   - the Settings folder and every folder the user allowed are kept as security-scoped
///     bookmarks (a plain path stops working after a relaunch), and opened at launch;
///   - "Next to the original" asks once per folder, with an open panel showing that folder
///     ("Allow … to save in “X”"), and remembers the answer;
///   - if the user declines, results go to Downloads (which the app has an entitlement for).
/// `JobQueue` calls `prepare` on the main actor before any job starts, so the converters
/// themselves always get an explicit output folder.
enum FolderAccess {
    private static let lock = NSLock()
    /// Folders being accessed through a security scope, by path.
    private static var opened: [String: URL] = [:]

    static let bookmarksKey = "allowedFolderBookmarks"
    static let outputFolderBookmarkKey = "outputFolderBookmark"

    // MARK: Bookmarks

    static func bookmark(for url: URL) -> Data? {
        #if APPSTORE
        try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        #else
        try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        #endif
    }

    /// Resolves a bookmark and starts accessing it. `refreshed` is set when the bookmark was
    /// stale and had to be recreated (the caller should store the new data).
    static func resolve(_ data: Data, refreshed: inout Data?) -> URL? {
        var stale = false
        #if APPSTORE
        let options: URL.BookmarkResolutionOptions = [.withSecurityScope]
        #else
        let options: URL.BookmarkResolutionOptions = []
        #endif
        guard let url = try? URL(resolvingBookmarkData: data, options: options, relativeTo: nil,
                                 bookmarkDataIsStale: &stale) else { return nil }
        beginAccess(url)
        if stale { refreshed = bookmark(for: url) }
        return url
    }

    static func resolve(_ data: Data) -> URL? {
        var ignored: Data?
        return resolve(data, refreshed: &ignored)
    }

    /// Starts accessing a security-scoped URL once; access lasts until the app quits.
    static func beginAccess(_ url: URL) {
        let path = url.standardizedFileURL.path
        lock.lock()
        defer { lock.unlock() }
        guard opened[path] == nil else { return }
        #if APPSTORE
        guard url.startAccessingSecurityScopedResource() else { return }
        #endif
        opened[path] = url
    }

    /// Opens every saved folder. Called once at launch.
    static func startAccessingSavedFolders() {
        let defaults = UserDefaults.standard
        var list = defaults.array(forKey: bookmarksKey) as? [Data] ?? []
        var changed = false
        list = list.compactMap { (data: Data) -> Data? in
            var refreshed: Data?
            guard resolve(data, refreshed: &refreshed) != nil else { changed = true; return nil }
            if let refreshed { changed = true; return refreshed }
            return data
        }
        if changed { defaults.set(list, forKey: bookmarksKey) }
        _ = savedOutputFolder
    }

    // MARK: Output folder from Settings

    /// Stores the folder chosen in Settings as a bookmark. Returns false if that failed.
    @discardableResult
    static func saveOutputFolder(_ url: URL) -> Bool {
        guard let data = bookmark(for: url) else { return false }
        UserDefaults.standard.set(data, forKey: outputFolderBookmarkKey)
        beginAccess(url)
        return true
    }

    /// The folder chosen in Settings, opened for access; nil if none or it's gone.
    static var savedOutputFolder: URL? {
        let defaults = UserDefaults.standard
        guard let data = defaults.data(forKey: outputFolderBookmarkKey) else { return nil }
        var refreshed: Data?
        guard let url = resolve(data, refreshed: &refreshed) else { return nil }
        if let refreshed { defaults.set(refreshed, forKey: outputFolderBookmarkKey) }
        return url
    }

    // MARK: Folders allowed one at a time

    private static func remember(_ folder: URL) {
        guard let data = bookmark(for: folder) else { return }
        let defaults = UserDefaults.standard
        var list = defaults.array(forKey: bookmarksKey) as? [Data] ?? []
        list.append(data)
        defaults.set(list, forKey: bookmarksKey)
        beginAccess(folder)
    }

    /// Folders the user declined this session; they aren't asked about again until relaunch.
    @MainActor private static var declined = Set<String>()

    /// The user's real Downloads folder (inside the sandbox, the home directory is the container).
    static var downloads: URL {
        if let home = getpwuid(getuid())?.pointee.pw_dir {
            let path = FileManager.default.string(withFileSystemRepresentation: home, length: strlen(home))
            return URL(fileURLWithPath: path, isDirectory: true).appendingPathComponent("Downloads", isDirectory: true)
        }
        return FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
    }

    /// True when the app may already write into `folder`.
    static func canWrite(in folder: URL) -> Bool {
        let path = folder.standardizedFileURL.resolvingSymlinksInPath().path
        var roots = [downloads.path, NSHomeDirectory(), FileManager.default.temporaryDirectory.path]
        lock.lock()
        roots += opened.keys
        lock.unlock()
        let known = roots.contains { root in
            let r = URL(fileURLWithPath: root).standardizedFileURL.resolvingSymlinksInPath().path
            return path == r || path.hasPrefix(r.hasSuffix("/") ? r : r + "/")
        }
        if known { return true }
        // Files inside a dropped folder can be written next to: the drop opened the whole folder.
        // The sandbox has no "may I write here?" query, so try with a hidden file.
        let probe = folder.appendingPathComponent(".\(UUID().uuidString).tmp")
        guard FileManager.default.createFile(atPath: probe.path, contents: nil) else { return false }
        try? FileManager.default.removeItem(at: probe)
        return true
    }

    /// Asks the user to allow saving in `folder`. Returns the folder to use: the one they
    /// confirmed (they may pick another), or nil if they declined.
    @MainActor
    private static func ask(for folder: URL) -> URL? {
        let panel = NSOpenPanel()
        panel.message = "Allow \(AppInfo.name) to save in “\(folder.lastPathComponent)”"
        panel.prompt = "Allow"
        panel.directoryURL = folder
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let chosen = panel.url else { return nil }
        remember(chosen)
        return chosen
    }

    // MARK: Before jobs start

    /// Options for each input, with the output folder filled in. In the download build this
    /// is `options` unchanged for every file.
    @MainActor
    static func prepare(_ inputs: [URL], options: ConversionOptions) -> (URL) -> ConversionOptions {
        #if APPSTORE
        if options.outputFolder != nil { return { _ in options } }
        var folders: [String: URL] = [:]
        for input in inputs {
            let parent = input.deletingLastPathComponent().standardizedFileURL
            guard folders[parent.path] == nil else { continue }
            folders[parent.path] = destination(for: parent)
        }
        return { input in
            var copy = options
            copy.outputFolder = folders[input.deletingLastPathComponent().standardizedFileURL.path] ?? downloads
            return copy
        }
        #else
        return { _ in options }
        #endif
    }

    @MainActor
    private static func destination(for parent: URL) -> URL {
        if canWrite(in: parent) { return parent }
        if declined.contains(parent.path) { return downloads }
        if let chosen = ask(for: parent) { return chosen }
        declined.insert(parent.path)
        return downloads
    }
}
