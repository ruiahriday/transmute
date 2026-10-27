import AppKit
import CryptoKit
import SwiftUI
import UniformTypeIdentifiers

/// "Create link": drop files on the wheel's Link bubble and Spinform uploads them, encrypted,
/// to the Spinform link service and copies a link anyone can download from for 7 days.
/// The service and its format are in server/links (FORMAT.md). The key is made here and only
/// travels in the link after "#", so the service never sees the file or its name.
enum LinkService {
    /// The service's address and the token this build sends. Builds without them (the service
    /// isn't set up yet) leave Link off every wheel.
    static var endpoint: URL? {
        let text = ProcessInfo.processInfo.environment["SPINFORM_LINK_SERVICE"]
            ?? Bundle.main.object(forInfoDictionaryKey: "SpinformLinkService") as? String ?? ""
        return text.isEmpty ? nil : URL(string: text.hasSuffix("/") ? String(text.dropLast()) : text)
    }

    static var token: String? {
        let text = ProcessInfo.processInfo.environment["SPINFORM_LINK_TOKEN"]
            ?? Bundle.main.object(forInfoDictionaryKey: "SpinformLinkToken") as? String ?? ""
        return text.isEmpty ? nil : text
    }

    static var isAvailable: Bool { endpoint != nil && token != nil }

    static let chunk = 8 * 1024 * 1024
    static let tag = 16
    /// The service's limit (MAX_BYTES in wrangler.toml).
    static let maxBytes: Int64 = 5 * 1024 * 1024 * 1024
    static let days = 7
}

enum LinkCrypto {
    static func chunkNonce(_ index: Int, last: Bool) -> AES.GCM.Nonce {
        var bytes = [UInt8](repeating: 0, count: 12)
        bytes[0] = last ? 1 : 0
        withUnsafeBytes(of: UInt64(index).bigEndian) { bytes.replaceSubrange(4..<12, with: $0) }
        return try! AES.GCM.Nonce(data: bytes)
    }

    static let metaNonce = try! AES.GCM.Nonce(data: [0xFF, 0xFF, 0xFF, 0xFF] + [UInt8](repeating: 0, count: 8))

    /// Ciphertext followed by the 16-byte tag.
    static func seal(_ data: Data, key: SymmetricKey, nonce: AES.GCM.Nonce) throws -> Data {
        let box = try AES.GCM.seal(data, using: key, nonce: nonce)
        return box.ciphertext + box.tag
    }

    static func open(_ sealed: Data, key: SymmetricKey, nonce: AES.GCM.Nonce) throws -> Data {
        guard sealed.count >= LinkService.tag else { throw ConversionError("Damaged data.") }
        let box = try AES.GCM.SealedBox(nonce: nonce, ciphertext: sealed.dropLast(LinkService.tag),
                                        tag: sealed.suffix(LinkService.tag))
        return try AES.GCM.open(box, using: key)
    }

    static func base64url(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    static func fromBase64url(_ text: String) -> Data? {
        var s = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s += "=" }
        return Data(base64Encoded: s)
    }

    /// Chunks a file of this size is cut into (an empty file is one empty chunk).
    static func chunkCount(_ size: Int64) -> Int { max(1, Int((size + Int64(LinkService.chunk) - 1) / Int64(LinkService.chunk))) }
}

/// A link made on this Mac, kept so it can be copied again or deleted early.
struct SharedLink: Codable, Identifiable, Equatable {
    let id: String
    let name: String
    let size: Int64
    /// The whole link, key included.
    let url: String
    let deleteToken: String
    let expires: Date
    let service: String

    var isExpired: Bool { expires < Date() }
}

@MainActor
final class SharedLinks: ObservableObject {
    static let shared = SharedLinks()
    private static let prefKey = "sharedLinks"

    @Published private(set) var links: [SharedLink] = []

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.prefKey),
           let saved = try? JSONDecoder().decode([SharedLink].self, from: data) {
            links = saved.filter { !$0.isExpired }
        }
    }

    func add(_ link: SharedLink) {
        links.insert(link, at: 0)
        save()
    }

    /// Deletes the file from the service now instead of waiting for it to expire.
    func delete(_ link: SharedLink) async throws {
        try await LinkUploader.deleteRemote(service: link.service, id: link.id, deleteToken: link.deleteToken)
        links.removeAll { $0.id == link.id }
        save()
    }

    func copy(_ link: SharedLink) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(link.url, forType: .string)
    }

    private func save() {
        links.removeAll(where: \.isExpired)
        UserDefaults.standard.set(try? JSONEncoder().encode(links), forKey: Self.prefKey)
    }
}

enum LinkUploader {
    struct Progress: Sendable {
        var sent: Int64
        var total: Int64
    }

    /// One file to send: the file itself, or a zip of several files or a folder.
    static func prepare(_ urls: [URL]) async throws -> (file: URL, cleanup: URL?) {
        if urls.count == 1, !urls[0].hasDirectoryPath { return (urls[0], nil) }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("spinform-link-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let options = ConversionOptions(quality: 0.85, outputFolder: folder, stripMetadata: false)
        let name = urls.count == 1 ? nil : "\(urls.count) files"
        let zip = try await ArchiveTool.compress(urls, to: .zip, name: name, options: options)
        return (zip, folder)
    }

    /// Encrypts and uploads one file; returns the link (key included).
    static func upload(_ file: URL, service: URL, token: String,
                       progress: @escaping @Sendable (Progress) -> Void) async throws -> SharedLink {
        let size = OutputPaths.fileSize(file)
        guard size <= LinkService.maxBytes else {
            throw ConversionError("Links can hold up to 5 GB. This is \(size.formattedSize).")
        }
        let key = SymmetricKey(size: .bits256)
        let chunks = LinkCrypto.chunkCount(size)
        let total = size + Int64(chunks * LinkService.tag)
        let type = UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        let metaJSON = try JSONSerialization.data(withJSONObject: ["name": file.lastPathComponent, "size": size, "type": type])
        let meta = try LinkCrypto.seal(metaJSON, key: key, nonce: LinkCrypto.metaNonce)

        let created: [String: Any] = try await call(service, "POST", "/api/links", token: token,
                                                    json: ["size": total, "parts": chunks, "meta": meta.base64EncodedString()])
        guard let id = created["id"] as? String, let pageURL = created["url"] as? String,
              let deleteToken = created["deleteToken"] as? String else { throw ConversionError("The link service gave an odd answer.") }

        do {
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            var parts: [[String: Any]] = []
            var sent: Int64 = 0
            progress(Progress(sent: 0, total: total))
            for index in 0..<chunks {
                try Task.checkCancellation()
                let plain = try handle.read(upToCount: LinkService.chunk) ?? Data()
                let sealed = try LinkCrypto.seal(plain, key: key, nonce: LinkCrypto.chunkNonce(index, last: index == chunks - 1))
                let answer: [String: Any] = try await call(service, "PUT", "/api/links/\(id)/parts/\(index + 1)", token: token,
                                                           body: sealed, retries: 4)
                guard let etag = answer["etag"] as? String else { throw ConversionError("The link service lost part \(index + 1).") }
                parts.append(["partNumber": index + 1, "etag": etag])
                sent += Int64(sealed.count)
                progress(Progress(sent: sent, total: total))
            }
            let done: [String: Any] = try await call(service, "POST", "/api/links/\(id)/complete", token: token,
                                                     json: ["parts": parts], retries: 2)
            let expires = (done["expires"] as? String).flatMap { ISO8601DateFormatter.withFractions.date(from: $0) }
                ?? Date().addingTimeInterval(Double(LinkService.days) * 86400)
            return SharedLink(id: id, name: file.lastPathComponent, size: size,
                              url: pageURL + "#" + LinkCrypto.base64url(key.withUnsafeBytes { Data($0) }),
                              deleteToken: deleteToken, expires: expires, service: service.absoluteString)
        } catch {
            // Don't leave half an upload behind.
            try? await deleteRemote(service: service.absoluteString, id: id, deleteToken: deleteToken)
            throw error
        }
    }

    static func deleteRemote(service: String, id: String, deleteToken: String) async throws {
        guard let base = URL(string: service) else { return }
        var request = URLRequest(url: base.appendingPathComponent("api/links/\(id)"))
        request.httpMethod = "DELETE"
        request.setValue(deleteToken, forHTTPHeaderField: "X-Delete-Token")
        let (_, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        // 404: already gone, which is what we wanted.
        guard status == 200 || status == 404 else { throw ConversionError("The link service didn't delete it (\(status)).") }
    }

    private static func call(_ service: URL, _ method: String, _ path: String, token: String,
                             json: [String: Any]? = nil, body: Data? = nil, retries: Int = 0) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: service.absoluteString + path)!)
        request.httpMethod = method
        request.timeoutInterval = 120
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let json {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: json)
        } else if let body {
            request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }
        var attempt = 0
        while true {
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
                if (200..<300).contains(status) { return object }
                let message = object["error"] as? String ?? "The link service answered \(status)."
                // Our mistakes and refusals won't fix themselves; the server's might.
                if status < 500 { throw LinkError.refused(message) }
                throw LinkError.server(message)
            } catch let error as LinkError {
                if case .refused(let message) = error { throw ConversionError(message) }
                if attempt >= retries { throw ConversionError(error.message) }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if (error as? URLError)?.code == .cancelled { throw CancellationError() }
                if attempt >= retries { throw ConversionError("Couldn't reach the link service: \(error.localizedDescription)") }
            }
            attempt += 1
            try await Task.sleep(nanoseconds: UInt64(1 << attempt) * 1_000_000_000)
        }
    }

    private enum LinkError: Error {
        case refused(String), server(String)
        var message: String {
            switch self {
            case .refused(let m), .server(let m): m
            }
        }
    }
}

extension ISO8601DateFormatter {
    static let withFractions: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}

// MARK: The little window while a link is made

@MainActor
final class LinkPanelController {
    static let shared = LinkPanelController()
    private var panel: NSPanel?
    private let model = LinkPanelModel()
    private var task: Task<Void, Never>?

    func create(_ urls: [URL]) {
        guard let service = LinkService.endpoint, let token = LinkService.token, !urls.isEmpty else { return }
        task?.cancel()
        model.state = .preparing(urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) files")
        show()
        task = Task { [model] in
            var cleanup: URL?
            defer { if let cleanup { try? FileManager.default.removeItem(at: cleanup) } }
            do {
                let prepared = try await LinkUploader.prepare(urls)
                cleanup = prepared.cleanup
                let name = prepared.file.lastPathComponent
                model.state = .uploading(name, 0, OutputPaths.fileSize(prepared.file))
                let link = try await LinkUploader.upload(prepared.file, service: service, token: token) { p in
                    Task { @MainActor in
                        if case .uploading = model.state { model.state = .uploading(name, Double(p.sent) / Double(max(p.total, 1)), p.total) }
                    }
                }
                SharedLinks.shared.add(link)
                SharedLinks.shared.copy(link)
                model.state = .done(link)
                self.hide(after: 8)
            } catch is CancellationError {
                self.hide(after: 0)
            } catch {
                model.state = .failed(error.localizedDescription)
                self.hide(after: 10)
            }
        }
    }

    func cancel() {
        task?.cancel()
        hide(after: 0)
    }

    func hide(after seconds: Double) {
        let state = model.state
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard let self, self.model.state == state, !self.model.hovering || seconds == 0 else { return }
            self.panel?.orderOut(nil)
        }
    }

    private func show() {
        let panel = self.panel ?? {
            let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.isOpaque = false
            p.backgroundColor = .clear
            p.level = .floating
            p.hidesOnDeactivate = false
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            p.contentView = NSHostingView(rootView: LinkPanelView(model: model))
            return p
        }()
        self.panel = panel
        if let frame = NSScreen.main?.visibleFrame {
            panel.setFrame(NSRect(x: frame.maxX - 344, y: frame.maxY - 102, width: 334, height: 94), display: true)
        }
        panel.orderFrontRegardless()
    }
}

@MainActor
final class LinkPanelModel: ObservableObject {
    enum State: Equatable {
        case preparing(String)
        case uploading(String, Double, Int64)
        case done(SharedLink)
        case failed(String)
    }

    @Published var state: State = .preparing("")
    @Published var hovering = false
}

struct LinkPanelView: View {
    @ObservedObject var model: LinkPanelModel

    var body: some View {
        HStack(spacing: 12) {
            icon.frame(width: 28)
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(Theme.Fonts.bodyStrong)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                detail
            }
            Spacer(minLength: 0)
            buttons
        }
        .padding(.horizontal, 14)
        .frame(width: 322, height: 82, alignment: .leading)
        .floatingPanel()
        .padding(6)
        .tint(Theme.accent)
        .onHover { model.hovering = $0 }
    }

    @ViewBuilder private var icon: some View {
        switch model.state {
        case .preparing, .uploading:
            SpinningMark(secondsPerTurn: 3).frame(width: 28, height: 28)
        case .done:
            Image(systemName: "link.circle.fill").font(.system(size: 24, weight: .semibold)).foregroundStyle(Theme.success)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 22, weight: .semibold)).foregroundStyle(Theme.warning)
        }
    }

    private var title: String {
        switch model.state {
        case .preparing(let name): "Zipping \(name)…"
        case .uploading(let name, _, _): "Uploading \(name)"
        case .done: "Link copied"
        case .failed: "Couldn't create the link"
        }
    }

    @ViewBuilder private var detail: some View {
        switch model.state {
        case .preparing:
            GlowProgressBar(value: 0, tint: Theme.accent)
        case .uploading(_, let fraction, let total):
            VStack(alignment: .leading, spacing: 3) {
                GlowProgressBar(value: fraction, tint: Theme.accent)
                Text("\(Int(fraction * 100))% of \(total.formattedSize) · encrypted")
                    .font(Theme.Fonts.caption).foregroundStyle(Theme.textSecondary)
            }
        case .done(let link):
            Text("\(link.name) · works for \(LinkService.days) days. Paste it anywhere.")
                .font(Theme.Fonts.caption).foregroundStyle(Theme.textSecondary).lineLimit(2)
        case .failed(let message):
            Text(message).font(Theme.Fonts.caption).foregroundStyle(Theme.textSecondary).lineLimit(2)
        }
    }

    @ViewBuilder private var buttons: some View {
        switch model.state {
        case .preparing, .uploading:
            Button("Cancel") { LinkPanelController.shared.cancel() }.controlSize(.small)
        case .done(let link):
            Button("Copy") { SharedLinks.shared.copy(link) }.controlSize(.small)
        case .failed:
            Button("Close") { LinkPanelController.shared.hide(after: 0) }.controlSize(.small)
        }
    }
}

// MARK: Settings

/// Links made on this Mac that still work, with Copy and Delete.
struct SharedLinksSection: View {
    @ObservedObject private var store = SharedLinks.shared
    @State private var error: String?

    var body: some View {
        if LinkService.isAvailable {
            Section("Links") {
                let live = store.links.filter { !$0.isExpired }
                if live.isEmpty {
                    Text("Hold the actions key while dragging files and drop them on Link. Links last \(LinkService.days) days.")
                        .font(Theme.Fonts.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
                ForEach(live) { link in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(link.name).lineLimit(1).truncationMode(.middle)
                            Text("\(link.size.formattedSize) · until \(link.expires.formatted(date: .abbreviated, time: .shortened))")
                                .font(Theme.Fonts.caption).foregroundStyle(Theme.textSecondary)
                        }
                        Spacer()
                        Button("Copy") { store.copy(link) }
                        Button("Delete") {
                            Task {
                                do { try await store.delete(link) } catch { self.error = error.localizedDescription }
                            }
                        }
                    }
                }
                if let error {
                    Text(error).font(Theme.Fonts.caption).foregroundStyle(Theme.warning)
                }
            }
        }
    }
}
