import Foundation
import Testing

@testable import MarkdownCore

@Test("Document resources resolve inside the containing directory")
func resolvesLocalResource() {
    let documentURL = URL(fileURLWithPath: "/tmp/Notes/page.md")
    let resolved = MarkdownResourceResolver.resolve(
        reference: "images/photo%201.png?width=600#preview",
        relativeTo: documentURL
    )

    #expect(resolved?.path == "/tmp/Notes/images/photo 1.png")
}

@Test("Traversal and external resource URLs are rejected")
func rejectsUnsafeResource() {
    let documentURL = URL(fileURLWithPath: "/tmp/Notes/page.md")

    #expect(MarkdownResourceResolver.resolve(reference: "../../secret", relativeTo: documentURL) == nil)
    #expect(MarkdownResourceResolver.resolve(reference: "/etc/passwd", relativeTo: documentURL) == nil)
    #expect(MarkdownResourceResolver.resolve(reference: "https://example.com/a.png", relativeTo: documentURL) == nil)
}

@Test("Sibling paths that merely share a string prefix are rejected")
func rejectsPrefixCollision() {
    let documentURL = URL(fileURLWithPath: "/tmp/Note/page.md")

    #expect(MarkdownResourceResolver.resolve(reference: "../Notebook/secret.png", relativeTo: documentURL) == nil)
}
