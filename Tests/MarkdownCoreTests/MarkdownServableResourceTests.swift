import Foundation
import Testing

@testable import MarkdownCore

private let servableRoot = URL(fileURLWithPath: "/tmp/Notes")

@Test("Servable resources allow common image and static asset types")
func allowsServableTypes() {
    for path in [
        "images/photo.png",
        "images/photo.jpg",
        "images/photo.jpeg",
        "images/photo.gif",
        "images/photo.webp",
        "images/photo.svg",
        "images/photo.avif",
        "images/photo.heic",
        "images/photo.bmp",
        "images/photo.tiff",
        "style.css",
        "fonts/serif.woff2",
    ] {
        #expect(
            MarkdownResourceResolver.resolveServableResource(path: path, relativeTo: servableRoot)
                == servableRoot.appendingPathComponent(path)
        )
    }
}

@Test("Servable resources reject types outside the allowlist")
func rejectsNonAllowlistedTypes() {
    for path in ["script.js", "notes.md", "archive.zip", "no-extension", "data.json"] {
        #expect(
            MarkdownResourceResolver.resolveServableResource(path: path, relativeTo: servableRoot)
                == nil
        )
    }
}

@Test("Servable resources reject hidden path components at any level")
func rejectsHiddenComponents() {
    for path in [".env", ".git/config", "images/.secret.png", ".config/app.png"] {
        #expect(
            MarkdownResourceResolver.resolveServableResource(path: path, relativeTo: servableRoot)
                == nil
        )
    }
}

@Test("Servable resources reject traversal and absolute paths")
func rejectsTraversalAndAbsolutePaths() {
    for path in ["../secret.png", "../../etc/passwd.png", "/etc/secret.png", ""] {
        #expect(
            MarkdownResourceResolver.resolveServableResource(path: path, relativeTo: servableRoot)
                == nil
        )
    }
}

@Test("Servable resources reject sibling directories that share a string prefix")
func rejectsPrefixCollisionForServableResource() {
    let root = URL(fileURLWithPath: "/tmp/Note")

    #expect(
        MarkdownResourceResolver.resolveServableResource(
            path: "../Notebook/secret.png",
            relativeTo: root
        ) == nil
    )
}
