import MarkdownIt from "markdown-it";
import type { Token } from "markdown-it";
import { t } from "./i18n";

export type SafetyIssueCode =
  | "raw-html"
  | "html-comment"
  | "front-matter"
  | "footnote"
  | "table-of-contents"
  | "github-alert"
  | "serializer-autolink-backslash"
  | "serializer-round-trip";

export interface SafetyIssue {
  code: SafetyIssueCode;
  message: string;
  line?: number;
}

export interface SafetyReport {
  safeForWysiwym: boolean;
  issues: SafetyIssue[];
}

const parser = new MarkdownIt({ html: true, linkify: true });

function lineNumber(source: string, offset: number): number {
  return source.slice(0, offset).split("\n").length;
}

function addMatch(
  source: string,
  expression: RegExp,
  code: SafetyIssueCode,
  message: string,
  issues: SafetyIssue[],
): void {
  const match = expression.exec(source);
  if (match?.index !== undefined) {
    // Patterns may swallow preceding whitespace/newlines (e.g. the raw-html
    // check); report the line where the matched content actually starts.
    const contentOffset = match[0].search(/\S/);
    const index = match.index + (contentOffset > 0 ? contentOffset : 0);
    issues.push({ code, message, line: lineNumber(source, index) });
  }
}

// CommonMark autolinks (<scheme:...> and <email>) look like raw HTML to the
// raw-html check below, so mask them first. Replacement keeps the original
// length and newlines so reported line numbers stay accurate.
const AUTOLINK_URI = /<[A-Za-z][A-Za-z0-9+.-]{1,31}:[^<>\s]*>/g;
const AUTOLINK_EMAIL =
  /<[A-Za-z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?)*>/g;

function maskAutolinks(source: string): string {
  return source
    .replace(AUTOLINK_URI, (match) => " ".repeat(match.length))
    .replace(AUTOLINK_EMAIL, (match) => " ".repeat(match.length));
}

export function analyzeMarkdownSafety(source: string): SafetyReport {
  const issues: SafetyIssue[] = [];

  addMatch(
    source,
    /<!--[\s\S]*?-->/m,
    "html-comment",
    t("safety.html-comment"),
    issues,
  );
  addMatch(
    maskAutolinks(source),
    /(^|\n)\s*<\/?[A-Za-z][^>]*>/m,
    "raw-html",
    t("safety.raw-html"),
    issues,
  );
  addMatch(
    source,
    /^---\s*\n[\s\S]*?\n(?:---|\.\.\.)\s*(?:\n|$)/,
    "front-matter",
    t("safety.front-matter"),
    issues,
  );
  addMatch(
    source,
    /(?:\[\^[^\]]+\])|(?:^\[\^[^\]]+\]:)/m,
    "footnote",
    t("safety.footnote"),
    issues,
  );
  // These extensions are deliberately rendered only by the reading surface.
  // Milkdown treats their markers as ordinary text and escapes the brackets
  // when serializing, so rich editing would silently rewrite the source.
  addMatch(
    source,
    /(^|\n)[ \t]*\[\[?toc\]?\][ \t]*(?=\n|$)/i,
    "table-of-contents",
    t("safety.table-of-contents"),
    issues,
  );
  addMatch(
    source,
    /(^|\n)[ \t]*>+[ \t]*\[!(?:NOTE|TIP|IMPORTANT|WARNING|CAUTION)\]/i,
    "github-alert",
    t("safety.github-alert"),
    issues,
  );
  addMatch(
    source,
    /<[^>\n]*\\[^>\n]*>/,
    "serializer-autolink-backslash",
    t("safety.autolink-backslash"),
    issues,
  );

  return { safeForWysiwym: issues.length === 0, issues };
}

interface ComparableToken {
  type: string;
  tag: string;
  nesting: number;
  attrs?: [string, string][];
  content?: string;
  info?: string;
  children?: ComparableToken[];
}

function comparableToken(token: Token): ComparableToken {
  const comparable: ComparableToken = {
    type: token.type,
    tag: token.tag,
    nesting: token.nesting,
  };

  if (token.attrs?.length) {
    comparable.attrs = [...token.attrs]
      .map(([name, value]) => [name, String(value)] as [string, string])
      .sort(([a], [b]) => a.localeCompare(b));
  }
  if (token.children?.length) {
    comparable.children = token.children.map(comparableToken);
  } else if (
    token.type === "text" ||
    token.type === "code_inline" ||
    token.type === "code_block" ||
    token.type === "fence" ||
    token.type.startsWith("html_")
  ) {
    comparable.content = token.content;
  }
  if (token.type === "fence" && token.info.trim()) {
    comparable.info = token.info.trim();
  }

  return comparable;
}

export function semanticSignature(source: string): string {
  return JSON.stringify(parser.parse(source, {}).map(comparableToken));
}

export function isSemanticallyEquivalent(before: string, after: string): boolean {
  return semanticSignature(before) === semanticSignature(after);
}
