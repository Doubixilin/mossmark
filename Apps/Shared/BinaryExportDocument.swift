import SwiftUI
import UniformTypeIdentifiers

struct BinaryExportDocument: FileDocument {
    static let docxContentType = UTType(
        importedAs: "org.openxmlformats.wordprocessingml.document"
    )
    static let readableContentTypes: [UTType] = [.pdf, docxContentType, .html]
    static let writableContentTypes: [UTType] = [.pdf, docxContentType, .html]

    var data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.data = data
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
