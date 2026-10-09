import Foundation
import Testing

@testable import MarkdownCore

@Test("UTF-8 Markdown round-trips without changing bytes")
func utf8RoundTrip() throws {
    let original = Data("# 标题\n\nHello, **世界** 👋\n".utf8)
    let document = try MarkdownDocument(data: original)

    #expect(document.encoded() == original)
}

@Test("Invalid UTF-8 fails closed")
func invalidUTF8FailsClosed() {
    let invalid = Data([0xC3, 0x28])

    #expect(throws: MarkdownDocument.DecodingError.invalidUTF8) {
        try MarkdownDocument(data: invalid)
    }
}

@Test("UTF-8 BOM and CRLF bytes are preserved until content changes")
func metadataRoundTrip() throws {
    let bytes = Data([0xEF, 0xBB, 0xBF]) + Data("# Title\r\n\r\nBody\r\n".utf8)
    var document = try MarkdownDocument(data: bytes)

    #expect(document.hasUTF8ByteOrderMark)
    #expect(document.lineEnding == .carriageReturnLineFeed)
    #expect(document.encoded() == bytes)

    document.source = "# Changed\n\nBody\n"
    #expect(document.encoded() == Data([0xEF, 0xBB, 0xBF]) + Data("# Changed\r\n\r\nBody\r\n".utf8))
}

@Test("Line endings can be explicitly adopted")
func adoptsLineEndings() {
    var document = MarkdownDocument(source: "one\ntwo\n")
    document.adopt(lineEnding: .carriageReturnLineFeed)

    #expect(document.encoded() == Data("one\r\ntwo\r\n".utf8))
}

@Test("UTF-16 little-endian BOM files open and round-trip in the original encoding")
func utf16LittleEndianRoundTrip() throws {
    let original = Data([0xFF, 0xFE]) + "# 标题\n\nHello\n".data(using: .utf16LittleEndian)!
    var document = try MarkdownDocument(data: original)

    #expect(document.source == "# 标题\n\nHello\n")
    #expect(document.sourceEncoding == .utf16LittleEndian)
    #expect(!document.hasUTF8ByteOrderMark)
    #expect(document.encoded() == original)

    document.source = "# 标题\n\nChanged\n"
    let expected = Data([0xFF, 0xFE]) + "# 标题\n\nChanged\n".data(using: .utf16LittleEndian)!
    #expect(document.encoded() == expected)
}

@Test("UTF-16 big-endian BOM files open and round-trip in the original encoding")
func utf16BigEndianRoundTrip() throws {
    let original = Data([0xFE, 0xFF]) + "# Title\r\n\r\nBody\r\n".data(using: .utf16BigEndian)!
    var document = try MarkdownDocument(data: original)

    #expect(document.sourceEncoding == .utf16BigEndian)
    #expect(document.lineEnding == .carriageReturnLineFeed)
    #expect(document.encoded() == original)

    document.source = "# Changed\n\nBody\n"
    let expected = Data([0xFE, 0xFF]) + "# Changed\r\n\r\nBody\r\n".data(using: .utf16BigEndian)!
    #expect(document.encoded() == expected)
}

@Test("UTF-32 little-endian BOM is not misread as UTF-16")
func utf32LittleEndianStillFailsClosed() {
    let utf32 = Data([0xFF, 0xFE, 0x00, 0x00]) + "Hi".data(using: .utf32LittleEndian)!

    #expect(throws: MarkdownDocument.DecodingError.invalidUTF8) {
        try MarkdownDocument(data: utf32)
    }
}
