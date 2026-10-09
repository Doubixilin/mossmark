import Foundation
import Testing

@testable import MarkdownCore

@Test("Image resources copy to a unique portable relative path")
func importsPortableImageResource() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let sourceDirectory = root.appendingPathComponent("Source", isDirectory: true)
    let documentDirectory = root.appendingPathComponent("Document", isDirectory: true)
    try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: documentDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let source = sourceDirectory.appendingPathComponent("cover photo.png")
    try Data([0x89, 0x50, 0x4E, 0x47]).write(to: source)
    let documentURL = documentDirectory.appendingPathComponent("notes.md")

    let first = try MarkdownAssetManager.importResource(
        at: source,
        relativeTo: documentURL
    )
    let second = try MarkdownAssetManager.importResource(
        at: source,
        relativeTo: documentURL
    )

    #expect(first == "images/cover%20photo.png")
    #expect(second == "images/cover%20photo-2.png")
    #expect(FileManager.default.fileExists(
        atPath: documentDirectory.appendingPathComponent("images/cover photo.png").path
    ))
}

@Test("Existing document-relative resources are not copied again")
func reusesExistingRelativeResource() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let imageDirectory = root.appendingPathComponent("assets", isDirectory: true)
    try FileManager.default.createDirectory(at: imageDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let image = imageDirectory.appendingPathComponent("图 1.jpg")
    try Data([0xFF, 0xD8, 0xFF]).write(to: image)
    let path = try MarkdownAssetManager.importResource(
        at: image,
        relativeTo: root.appendingPathComponent("page.md")
    )

    #expect(path == "assets/%E5%9B%BE%201.jpg")
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("images").path))
}

@Test("Markdown resource paths encode punctuation that can terminate destinations")
func encodesMarkdownDestinationPunctuation() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let image = root.appendingPathComponent("cover).png")
    try Data([0x89, 0x50, 0x4E, 0x47]).write(to: image)
    let path = try MarkdownAssetManager.importResource(
        at: image,
        relativeTo: root.appendingPathComponent("page.md")
    )

    #expect(path == "cover%29.png")
}

@Test("Photos image bytes import to a portable relative path")
func importsPhotoData() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let png = try #require(Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
    ))
    let path = try MarkdownAssetManager.importImage(
        data: png,
        suggestedFilename: "Camera Photo.HEIC",
        relativeTo: root.appendingPathComponent("notes.md")
    )

    #expect(path == "images/Camera-Photo.png")
    #expect(try Data(contentsOf: root.appendingPathComponent("images/Camera-Photo.png")) == png)
}

@Test("File-provider imports validate image contents instead of extensions")
func rejectsNonImageFileProviderItem() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let fakeImage = root.appendingPathComponent("not-really-an-image.png")
    try Data("plain text".utf8).write(to: fakeImage)

    #expect(throws: MarkdownAssetManager.ImportError.invalidSource) {
        try MarkdownAssetManager.importImage(
            at: fakeImage,
            relativeTo: root.appendingPathComponent("notes.md")
        )
    }
}
