/// The syntax contract shared by editing, preview and export.
///
/// `baseline` only contains syntax currently covered by the editor/preview
/// preservation contract. Enum cases outside that set remain explicit future
/// dialect candidates and must not be advertised as implemented.
public enum MarkdownDialect {
    public static let identifier = "localfirst-gfm-v1"

    public static let baseline: Set<Feature> = [
        .commonMark,
        .gfmTables,
        .gfmTaskLists,
        .gfmStrikethrough,
        .automaticLinks,
        .yamlFrontMatter,
        .footnotes,
        .math,
        .mermaid,
    ]

    public enum Feature: String, CaseIterable, Sendable {
        case commonMark
        case gfmTables
        case gfmTaskLists
        case gfmStrikethrough
        case automaticLinks
        case yamlFrontMatter
        case footnotes
        case tableOfContents
        case math
        case mermaid
        case githubAlerts
    }
}
