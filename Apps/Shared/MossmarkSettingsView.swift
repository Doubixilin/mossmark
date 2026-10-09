import SwiftUI

struct MossmarkSettingsView: View {
    @Environment(\.openURL) private var openURL
    @State private var legalDocument: LegalDocument?
    @AppStorage("mossmark.reading-font-size") private var readingFontSize = 17.0
    @AppStorage("mossmark.reading-content-width") private var readingContentWidth = 760.0
    @AppStorage("mossmark.spell-check") private var spellCheckEnabled = true
    @AppStorage("mossmark.full-width-layout") private var fullWidthLayout = false
    @AppStorage("mossmark.show-status-bar") private var showsStatusBar = true

    private static let fontSizeOptions: [Double] = [14, 15, 16, 17, 19, 21]

    var body: some View {
        Form {
            Section("settings.reading") {
                Picker("settings.font-size", selection: $readingFontSize) {
                    ForEach(Self.fontSizeOptions, id: \.self) { size in
                        Text(size, format: .number.precision(.fractionLength(0))).tag(size)
                    }
                }
                Picker("settings.content-width", selection: $readingContentWidth) {
                    Text("settings.width-narrow").tag(640.0)
                    Text("settings.width-standard").tag(760.0)
                    Text("settings.width-wide").tag(920.0)
                }
                Toggle("settings.spell-check", isOn: $spellCheckEnabled)
                Toggle("settings.full-width", isOn: $fullWidthLayout)
                Toggle("settings.status-bar", isOn: $showsStatusBar)
            }

            Section("settings.about") {
                LabeledContent("settings.app-name", value: "Mossmark")
                LabeledContent("settings.version", value: versionDescription)
            }

            Section("settings.project-and-help") {
                projectLink(title: "settings.project-page", url: MossmarkProjectConfiguration.repositoryURL)
                projectLink(title: "settings.report-issue", url: MossmarkProjectConfiguration.issuesURL)
                projectLink(title: "settings.privacy-policy", url: MossmarkProjectConfiguration.privacyPolicyURL)
                Button("settings.project-license") {
                    legalDocument = .projectLicense
                }
                Button("settings.legal-notices") {
                    legalDocument = .thirdPartyNotices
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("settings.title")
        .sheet(item: $legalDocument) { document in
            NavigationStack {
                LegalDocumentView(document: document)
            }
        }
        #if os(macOS)
        .frame(width: 520)
        .frame(idealHeight: 560, maxHeight: 720)
        #endif
    }

    @ViewBuilder
    private func projectLink(title: LocalizedStringKey, url: URL?) -> some View {
        if let url {
            Button(title) { openURL(url) }
        }
    }

    private var versionDescription: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "-"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "-"
        return "\(version) (\(build))"
    }
}

private enum LegalDocument: String, Identifiable {
    case projectLicense
    case thirdPartyNotices

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .projectLicense: "settings.project-license"
        case .thirdPartyNotices: "settings.legal-notices"
        }
    }

    var contents: String {
        let resource = self == .projectLicense ? "LICENSE" : "THIRD_PARTY_NOTICES"
        let fileExtension = self == .projectLicense ? nil : "md"
        guard let url = Bundle.main.url(forResource: resource, withExtension: fileExtension),
              let contents = try? String(contentsOf: url, encoding: .utf8)
        else {
            return String(localized: "settings.legal-notices-unavailable")
        }
        return contents
    }
}

private struct LegalDocumentView: View {
    let document: LegalDocument
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            Text(document.contents)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
        .navigationTitle(document.title)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("common.done") { dismiss() }
            }
        }
        #if os(macOS)
        .frame(minWidth: 620, minHeight: 520)
        #endif
    }
}
