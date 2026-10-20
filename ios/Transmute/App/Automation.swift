import SwiftUI

/// Screenshot mode for the build server: `--demo <folder> --screen <name>` fills the list with
/// sample files and opens one screen, so every screen can be checked without a person tapping.
@MainActor
final class Automation: ObservableObject {
    static let shared = Automation()

    /// "settings", "saved", "compress", "tools", or an editor: "image", "video", "audio", "info".
    @Published var screen: String?

    nonisolated static func value(after flag: String, in args: [String]) -> String? {
        guard let index = args.firstIndex(of: flag), index + 1 < args.count else { return nil }
        return args[index + 1]
    }

    /// An absolute path, or a folder inside the app's Documents.
    nonisolated static func folder(_ argument: String) -> URL {
        if argument.hasPrefix("/") { return URL(fileURLWithPath: argument, isDirectory: true) }
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documents.appendingPathComponent(argument, isDirectory: true)
    }

    static func demo(_ folder: URL, screen: String?) async {
        let screen = screen ?? "convert"
        if screen == "empty" { return }
        let names: [String] = switch screen {
        case "image": ["photo.jpg"]
        case "video": ["clip.mp4"]
        case "audio": ["song.mp3"]
        case "info": ["phone.heic", "photo.jpg"]
        default: ["photo.jpg", "phone.heic", "clip.mp4", "song.mp3", "report.docx", "budget.xlsx", "book.epub"]
        }
        let urls = names.map { folder.appendingPathComponent($0) }.filter { FileManager.default.fileExists(atPath: $0.path) }
        Library.shared.add(urls)
        let queue = JobQueue.shared

        if screen == "results" || screen == "saved" {
            let plan = queue.jobs.compactMap { job -> (UUID, JobOperation)? in
                Mobile.targets(for: job.url).first.map { (job.id, .convert($0)) }
            }
            queue.start(plan, options: Library.shared.options, reveal: false)
            while queue.isRunning { try? await Task.sleep(nanoseconds: 200_000_000) }
            Library.shared.noteOutputsChanged()
        }
        try? await Task.sleep(nanoseconds: 300_000_000)
        shared.screen = screen
    }
}
