import Foundation

/// The persisted Markdown source owned by the user.
public struct MarkdownDocument: Equatable, Sendable {
    public enum DecodingError: LocalizedError, Equatable {
        case invalidUTF8

        public var errorDescription: String? {
            String(localized: "error.document.invalid-utf8")
        }

        public var recoverySuggestion: String? {
            String(localized: "error.document.invalid-utf8-recovery")
        }
    }

    /// The character encoding the document was read from and is written back with.
    public enum SourceEncoding: String, Codable, CaseIterable, Sendable {
        case utf8
        case utf16LittleEndian
        case utf16BigEndian
    }

    public enum LineEnding: String, Codable, CaseIterable, Sendable {
        case lineFeed
        case carriageReturnLineFeed

        fileprivate var value: String {
            switch self {
            case .lineFeed: "\n"
            case .carriageReturnLineFeed: "\r\n"
            }
        }
    }

    public var source: String
    public private(set) var lineEnding: LineEnding
    public private(set) var hasUTF8ByteOrderMark: Bool
    public private(set) var sourceEncoding: SourceEncoding

    private var originalSource: String?
    private var originalData: Data?

    public init(
        source: String = "",
        lineEnding: LineEnding? = nil,
        hasUTF8ByteOrderMark: Bool = false,
        sourceEncoding: SourceEncoding = .utf8
    ) {
        self.source = source
        self.lineEnding = lineEnding ?? Self.detectLineEnding(in: source)
        self.hasUTF8ByteOrderMark = hasUTF8ByteOrderMark
        self.sourceEncoding = sourceEncoding
    }

    public init(data: Data) throws {
        let utf16BOMs: [(marker: [UInt8], encoding: SourceEncoding, stringEncoding: String.Encoding)] = [
            ([0xFF, 0xFE], .utf16LittleEndian, .utf16LittleEndian),
            ([0xFE, 0xFF], .utf16BigEndian, .utf16BigEndian),
        ]
        // FF FE 00 00 is the UTF-32 little-endian BOM; it must not be misread as UTF-16.
        let looksLikeUTF32LE = data.count >= 4
            && data[data.startIndex] == 0xFF && data[data.index(after: data.startIndex)] == 0xFE
            && data[data.index(data.startIndex, offsetBy: 2)] == 0x00
            && data[data.index(data.startIndex, offsetBy: 3)] == 0x00
        if !looksLikeUTF32LE {
            for bom in utf16BOMs where data.starts(with: bom.marker) {
                let payload = data.dropFirst(bom.marker.count)
                guard let source = String(data: payload, encoding: bom.stringEncoding) else {
                    throw DecodingError.invalidUTF8
                }
                self.source = source
                lineEnding = Self.detectLineEnding(in: source)
                hasUTF8ByteOrderMark = false
                sourceEncoding = bom.encoding
                originalSource = source
                originalData = data
                return
            }
        }

        let bom = Data([0xEF, 0xBB, 0xBF])
        let hasBOM = data.starts(with: bom)
        let payload = hasBOM ? data.dropFirst(bom.count) : data[...]
        guard let source = String(data: payload, encoding: .utf8) else {
            throw DecodingError.invalidUTF8
        }
        self.source = source
        lineEnding = Self.detectLineEnding(in: payload)
        hasUTF8ByteOrderMark = hasBOM
        sourceEncoding = .utf8
        originalSource = source
        originalData = data
    }

    public func encoded() -> Data {
        if source == originalSource, let originalData {
            return originalData
        }

        var normalized = source.replacingOccurrences(of: "\r\n", with: "\n")
        normalized = normalized.replacingOccurrences(of: "\r", with: "\n")
        if lineEnding == .carriageReturnLineFeed {
            normalized = normalized.replacingOccurrences(of: "\n", with: lineEnding.value)
        }

        var data = Data()
        switch sourceEncoding {
        case .utf8:
            if hasUTF8ByteOrderMark {
                data.append(contentsOf: [0xEF, 0xBB, 0xBF])
            }
            data.append(contentsOf: normalized.utf8)
        case .utf16LittleEndian:
            data.append(contentsOf: [0xFF, 0xFE])
            data.append(normalized.data(using: .utf16LittleEndian) ?? Data())
        case .utf16BigEndian:
            data.append(contentsOf: [0xFE, 0xFF])
            data.append(normalized.data(using: .utf16BigEndian) ?? Data())
        }
        return data
    }

    public mutating func adopt(lineEnding: LineEnding) {
        self.lineEnding = lineEnding
    }

    public mutating func setUTF8ByteOrderMark(_ enabled: Bool) {
        hasUTF8ByteOrderMark = enabled
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.source == rhs.source
            && lhs.lineEnding == rhs.lineEnding
            && lhs.hasUTF8ByteOrderMark == rhs.hasUTF8ByteOrderMark
            && lhs.sourceEncoding == rhs.sourceEncoding
    }

    private static func detectLineEnding(in source: String) -> LineEnding {
        var carriageReturnLineFeedCount = 0
        var lineFeedCount = 0
        var previousWasCarriageReturn = false

        // Scan scalars: "\r\n" is a single Character and would never match "\r".
        for scalar in source.unicodeScalars {
            if scalar == "\n" {
                if previousWasCarriageReturn {
                    carriageReturnLineFeedCount += 1
                } else {
                    lineFeedCount += 1
                }
            }
            previousWasCarriageReturn = scalar == "\r"
        }

        return carriageReturnLineFeedCount > lineFeedCount
            ? .carriageReturnLineFeed
            : .lineFeed
    }

    private static func detectLineEnding(in data: Data.SubSequence) -> LineEnding {
        var carriageReturnLineFeedCount = 0
        var loneLineFeedCount = 0
        var previousWasCarriageReturn = false

        for byte in data {
            if byte == 0x0A {
                if previousWasCarriageReturn {
                    carriageReturnLineFeedCount += 1
                } else {
                    loneLineFeedCount += 1
                }
            }
            previousWasCarriageReturn = byte == 0x0D
        }

        return carriageReturnLineFeedCount > loneLineFeedCount
            ? .carriageReturnLineFeed
            : .lineFeed
    }
}
