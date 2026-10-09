import Foundation

public enum MarkdownEditorMode: String, Codable, CaseIterable, Sendable {
    case preview
    case wysiwym
    case source

    public var localizationKey: String {
        switch self {
        case .wysiwym: "mode.edit"
        case .source: "mode.source"
        case .preview: "mode.reading"
        }
    }
}

public struct EditorDocumentSnapshot: Codable, Equatable, Sendable {
    public static let protocolVersion = 1

    public let protocolVersion: Int
    public let revision: Int
    public let markdown: String
    public let mode: MarkdownEditorMode

    public init(
        protocolVersion: Int = Self.protocolVersion,
        revision: Int,
        markdown: String,
        mode: MarkdownEditorMode
    ) {
        self.protocolVersion = protocolVersion
        self.revision = revision
        self.markdown = markdown
        self.mode = mode
    }

    public var isCompatible: Bool {
        protocolVersion == Self.protocolVersion
    }
}

public enum EditorBridgeMessageType: String, Codable, Sendable {
    case ready
    case change
    case mode
    case readingTap = "reading-tap"
    case outline
    case warning
    case error
}
