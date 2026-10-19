import SwiftUI

// Temporary stand-ins on the dev branch while MetadataEditor.swift and OfficeConverter.swift
// are being written, so the rest can be compiled. Not part of the app.
struct MetadataEdit: Equatable, Sendable {
    var changes: [String: String] = [:]
    var removeLocation = false
}

enum MetadataTool {
    static func write(_ edit: MetadataEdit, to input: URL, options: ConversionOptions) async throws -> URL {
        throw ConversionError("not built yet")
    }
}

struct MetadataEditorView: View {
    let url: URL
    let onSave: (MetadataEdit) -> Void
    let onCancel: () -> Void
    var body: some View { Text("Not built yet") }
}

enum OfficeConverter {
    static func convert(_ input: URL, kind: FileKind, to format: OutputFormat, options: ConversionOptions) async throws -> [URL] {
        throw ConversionError("not built yet")
    }

    static func requiredApp(for input: URL, to format: OutputFormat) -> String? {
        let kind = FileKind.of(input)
        if [.ebook, .presentation, .spreadsheet].contains(kind) || format == .epub || format == .pages
            || input.pathExtension.lowercased() == "pages" {
            return "the office module"
        }
        return nil
    }
}
