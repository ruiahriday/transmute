import Foundation

// Temporary stand-in on the dev branch while OfficeConverter.swift is being written, so the
// rest can be compiled. Not part of the app.
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
