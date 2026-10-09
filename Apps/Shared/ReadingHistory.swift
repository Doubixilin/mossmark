import Foundation
import SwiftUI

/// Persists the reading history (most recently opened documents) and the
/// per-document reading progress for the iOS document library. Entries are
/// keyed by the document path relative to the app's Documents directory, so
/// they survive app-container relocation between launches.
@MainActor
final class ReadingHistory: ObservableObject {
    struct Entry: Codable, Equatable, Identifiable {
        var path: String
        var lastOpenedAt: Date
        var scrollProgress: Double?

        var id: String { path }
    }

    private static let defaultsKey = "mossmark.reading-history"
    private static let maximumEntryCount = 50

    @Published private(set) var entries: [Entry] = []

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        MossmarkBrandMigration.migrateLegacyDefaults(defaults)
        if let data = defaults.data(forKey: Self.defaultsKey),
           let stored = try? JSONDecoder().decode([Entry].self, from: data)
        {
            entries = Self.sorted(stored)
        }
    }

    /// The document URLs most recently opened, newest first, limited to the
    /// files that still exist. Pure: call `pruneMissing()` from a task to
    /// also drop stale entries from storage.
    func recentDocumentURLs(limit: Int = 20) -> [URL] {
        entries
            .compactMap { entry -> URL? in
                guard let url = url(forStoredPath: entry.path),
                      FileManager.default.fileExists(atPath: url.path)
                else {
                    return nil
                }
                return url
            }
            .prefix(limit)
            .map { $0 }
    }

    /// Removes entries whose files no longer exist (deleted externally,
    /// e.g. through the Files app).
    func pruneMissing() {
        let stale = entries.filter { entry in
            guard let url = url(forStoredPath: entry.path) else { return true }
            return !FileManager.default.fileExists(atPath: url.path)
        }
        guard !stale.isEmpty else { return }
        let stalePaths = Set(stale.map(\.path))
        entries.removeAll { stalePaths.contains($0.path) }
        save()
    }

    func record(_ url: URL) {
        let path = storedPath(for: url)
        if let index = entries.firstIndex(where: { $0.path == path }) {
            entries[index].lastOpenedAt = Date()
        } else {
            entries.append(Entry(path: path, lastOpenedAt: Date(), scrollProgress: nil))
        }
        entries = Self.sorted(entries)
        if entries.count > Self.maximumEntryCount {
            entries = Array(entries.prefix(Self.maximumEntryCount))
        }
        save()
    }

    func remove(_ url: URL) {
        let path = storedPath(for: url)
        entries.removeAll { $0.path == path }
        save()
    }

    /// Rekeys an entry after the document was renamed, preserving its
    /// timestamp and reading progress.
    func move(from sourceURL: URL, to destinationURL: URL) {
        let sourcePath = storedPath(for: sourceURL)
        guard let index = entries.firstIndex(where: { $0.path == sourcePath }) else { return }
        entries[index].path = storedPath(for: destinationURL)
        save()
    }

    func scrollProgress(for url: URL) -> Double {
        let path = storedPath(for: url)
        return entries.first { $0.path == path }?.scrollProgress ?? 0
    }

    func setScrollProgress(_ progress: Double, for url: URL) {
        let path = storedPath(for: url)
        guard let index = entries.firstIndex(where: { $0.path == path }) else { return }
        entries[index].scrollProgress = progress
        save()
    }

    // MARK: - Path normalization

    private static var documentsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .standardizedFileURL
    }

    private func storedPath(for url: URL) -> String {
        let standardized = url.standardizedFileURL
        let root = Self.documentsDirectory
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        if standardized.path.hasPrefix(rootPath) {
            return String(standardized.path.dropFirst(rootPath.count))
        }
        return standardized.path
    }

    private func url(forStoredPath path: String) -> URL? {
        if path.hasPrefix("/") {
            return URL(fileURLWithPath: path)
        }
        return Self.documentsDirectory.appendingPathComponent(path)
    }

    private static func sorted(_ entries: [Entry]) -> [Entry] {
        entries.sorted { $0.lastOpenedAt > $1.lastOpenedAt }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}
