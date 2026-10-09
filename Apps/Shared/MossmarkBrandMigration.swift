import Foundation

enum MossmarkBrandMigration {
    /// Keeps preferences and reading progress when an existing QuietMark
    /// development build is updated in place under the frozen bundle ID.
    static func migrateLegacyDefaults(_ defaults: UserDefaults = .standard) {
        let keys = [
            "typography-preset",
            "reading-font-size",
            "reading-content-width",
            "spell-check",
            "full-width-layout",
            "show-status-bar",
            "reading-history",
        ]

        for key in keys {
            let legacyKey = "quietmark.\(key)"
            let currentKey = "mossmark.\(key)"
            guard defaults.object(forKey: currentKey) == nil,
                  let legacyValue = defaults.object(forKey: legacyKey)
            else {
                continue
            }
            defaults.set(legacyValue, forKey: currentKey)
        }
    }
}
