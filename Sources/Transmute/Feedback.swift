import AppKit
import SwiftUI

/// Beta feedback: opens a prefilled feedback form on GitHub, or copies the Mac's details
/// for testers who'd rather send them in a message.
enum Feedback {
    static let repository = "ruiahriday/transmute"

    static var version: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let short = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        return "\(short) (build \(build))"
    }

    /// Transmute's version, macOS version, Mac model and chip, one per line.
    static var details: String {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let chip = sysctlString("machdep.cpu.brand_string") ?? (isAppleSilicon ? "Apple Silicon" : "Intel")
        return """
        Transmute \(version)
        macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)
        Mac \(sysctlString("hw.model") ?? "unknown"), \(chip)
        ffmpeg \(Tools.ffmpeg == nil ? "missing" : "found")
        """
    }

    @MainActor
    static func openForm() {
        var parts = URLComponents(string: "https://github.com/\(repository)/issues/new")!
        parts.queryItems = [
            URLQueryItem(name: "template", value: "beta-feedback.yml"),
            URLQueryItem(name: "mac", value: details),
        ]
        if let url = parts.url { NSWorkspace.shared.open(url) }
    }

    @MainActor
    static func copyDetails() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(details, forType: .string)
    }

    private static var isAppleSilicon: Bool {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname("hw.optional.arm64", &value, &size, nil, 0) == 0 && value == 1
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }
}

/// Licences of bundled third-party software (Contents/Resources/ThirdPartyNotices.txt),
/// shown from Settings in the App Store build.
struct ThirdPartyNoticesView: View {
    @Environment(\.dismiss) private var dismiss

    private var text: String {
        guard let url = Bundle.main.url(forResource: "ThirdPartyNotices", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return "The notices file is missing from this copy of \(AppInfo.name)."
        }
        return text
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                Text(text)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            Divider()
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 520, height: 480)
    }
}
