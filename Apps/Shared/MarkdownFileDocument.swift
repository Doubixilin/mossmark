import MarkdownCore
import OSLog
import SwiftUI
import UniformTypeIdentifiers

private let documentIOLogger = Logger(
    subsystem: "com.doubixilin.mossmark",
    category: "DocumentIO"
)

struct MarkdownFileDocument: FileDocument {
    static let markdownContentType = UTType(
        importedAs: "net.daringfireball.markdown",
        conformingTo: .plainText
    )
    static let readableContentTypes: [UTType] = [markdownContentType, .plainText]
    static let writableContentTypes: [UTType] = [markdownContentType]

    var content: MarkdownDocument

    init(content: MarkdownDocument = MarkdownDocument()) {
        self.content = content
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        documentIOLogger.info(
            "DocumentIO read: \(data.count, privacy: .public) bytes, contentType=\(configuration.contentType.identifier, privacy: .public)"
        )
        content = try MarkdownDocument(data: data)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        let data = content.encoded()
        documentIOLogger.info(
            "DocumentIO write: \(data.count, privacy: .public) bytes, sourceChars=\(self.content.source.count, privacy: .public), existing=\(configuration.existingFile != nil, privacy: .public)"
        )
        return FileWrapper(regularFileWithContents: data)
    }

    /// Serialized bytes for the iOS document library's own atomic writes,
    /// which happen outside the FileDocument lifecycle. The encoding (and
    /// the "unmodified content returns the original bytes" guarantee inside
    /// `encoded()`) is identical to the FileDocument write path.
    func serializedData() -> Data {
        let data = content.encoded()
        documentIOLogger.info(
            "DocumentIO write: \(data.count, privacy: .public) bytes, sourceChars=\(self.content.source.count, privacy: .public), existing=direct"
        )
        return data
    }
}
