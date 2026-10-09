import { katex } from "@mdit/plugin-katex";
import MarkdownIt from "markdown-it";
import type { MarkdownIt as MarkdownItInstance, Token } from "markdown-it";
import footnote from "markdown-it-footnote";
import taskLists from "markdown-it-task-lists";

function escapeHTML(source: string): string {
  return source
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;");
}

function sourceForPresentation(source: string): string {
  let result = source.replace(/^\uFEFF?---[\t ]*\r?\n[\s\S]*?\r?\n(?:---|\.\.\.)[\t ]*(?:\r?\n|$)/, "");
  result = result.replace(/<!--[\s\S]*?-->/g, "");
  return result;
}

// Only these attribute-free tags may render as real HTML. Everything else
// markdown-it parsed as raw HTML must stay escaped text.
const SAFE_TAG_NAME = /^(?:mark|kbd|sub|sup|br)$/i;
const SAFE_TAG = /^<(\/?)\s*([A-Za-z][^\s/>]*)\s*(\/?)>$/;

// Returns the indices of html_inline tokens allowed to render: whitelisted
// tag names without attributes, with open/close pairs matched so a stray
// closing tag never escapes as a live element.
function allowedInlineHTML(tokens: Token[]): Set<number> {
  const allowed = new Set<number>();
  const open: Array<{ tag: string; index: number }> = [];
  tokens.forEach((token, index) => {
    if (token.type !== "html_inline") return;
    const match = SAFE_TAG.exec(token.content.trim());
    if (!match) return;
    const tag = match[2]?.toLowerCase() ?? "";
    if (!SAFE_TAG_NAME.test(tag)) return;
    if (match[1] === "/") {
      const last = open.pop();
      if (last?.tag === tag) {
        allowed.add(last.index);
        allowed.add(index);
      }
    } else if (match[3] === "/" || tag === "br") {
      allowed.add(index);
    } else {
      open.push({ tag, index });
    }
  });
  return allowed;
}

// An html_block is only allowed when it consists solely of whitespace and
// balanced whitelisted tags.
function isSafeHTMLBlock(content: string): boolean {
  const tags = content.match(/<\/?[A-Za-z][^>]*>/g) ?? [];
  if (content.replace(/<\/?[A-Za-z][^>]*>/g, "").trim() !== "") return false;
  const stack: string[] = [];
  for (const raw of tags) {
    const match = SAFE_TAG.exec(raw);
    const tag = match?.[2]?.toLowerCase() ?? "";
    if (!match || !SAFE_TAG_NAME.test(tag)) return false;
    if (match[1] === "/") {
      if (stack.pop() !== tag) return false;
    } else if (match[3] !== "/" && tag !== "br") {
      stack.push(tag);
    }
  }
  return stack.length === 0;
}

// markdown-it-task-lists injects a checkbox as an html_inline token. We retag
// only that plugin-generated first child below, so identical user-authored raw
// HTML still follows the normal escape policy. Labels stay ordinary text so
// task content can never become plugin-generated HTML.
const GENERATED_TASK_CHECKBOX =
  /^<input class="task-list-item-checkbox"(?: checked="")? disabled="" type="checkbox">$/;

// GitHub Alerts: a blockquote whose first line is exactly the [!KIND] marker
// renders as a styled callout. The marker stays plain text in the Markdown
// source, so Milkdown sees an ordinary blockquote and round-trips losslessly.
const ALERT_MARKER = /^\[!(NOTE|TIP|IMPORTANT|WARNING|CAUTION)\]/;

function githubAlerts(instance: MarkdownItInstance): void {
  instance.core.ruler.push("github-alert", (state) => {
    const tokens = state.tokens;
    for (let index = 0; index < tokens.length; index += 1) {
      const open = tokens[index];
      if (open?.type !== "blockquote_open") continue;
      const paragraph = tokens[index + 1];
      const inline = tokens[index + 2];
      if (paragraph?.type !== "paragraph_open" || inline?.type !== "inline") {
        continue;
      }
      const marker = ALERT_MARKER.exec(inline.content);
      if (!marker) continue;

      const kind = (marker[1] ?? "").toLowerCase();
      // Strip the marker from the rendered text, keeping any content that
      // follows it on the same line.
      inline.content = inline.content.slice(marker[0].length).replace(/^[ \t]+/, "");
      const firstChild = inline.children?.[0];
      if (firstChild?.type === "text") {
        firstChild.content = firstChild.content
          .slice(marker[0].length)
          .replace(/^[ \t]+/, "");
      }

      // Re-tag the quote as a div; markdown-it's default token renderer
      // picks up the new tag, so no custom render rules are needed.
      open.tag = "div";
      open.attrSet("class", `md-alert md-alert-${kind}`);
      // Find the matching blockquote_close, accounting for nested quotes.
      let depth = 1;
      for (let cursor = index + 1; cursor < tokens.length; cursor += 1) {
        const type = tokens[cursor]?.type;
        if (type === "blockquote_open") depth += 1;
        if (type === "blockquote_close") {
          depth -= 1;
          if (depth === 0) {
            tokens[cursor]!.tag = "div";
            break;
          }
        }
      }
    }
  });
}

export function createRenderer(): MarkdownItInstance {
  // html: true so markdown-it produces html_inline/html_block tokens; the
  // render rules below then re-escape everything except the whitelisted
  // attribute-free subset (allowedInlineHTML / isSafeHTMLBlock).
  const renderer = new MarkdownIt({
    html: true,
    linkify: true,
    typographer: false,
    breaks: false,
  })
    .use(footnote)
    .use(taskLists, { enabled: false, label: false })
    .use(katex, {
      throwOnError: false,
      strict: "warn",
      trust: false,
      maxExpand: 1000,
      maxSize: 20,
    })
    .use(githubAlerts);

  renderer.core.ruler.after(
    "github-task-lists",
    "mossmark-task-checkbox",
    (state) => {
      const tokens = state.tokens;
      for (let index = 2; index < tokens.length; index += 1) {
        const inline = tokens[index];
        const paragraph = tokens[index - 1];
        const item = tokens[index - 2];
        if (
          inline?.type !== "inline" ||
          paragraph?.type !== "paragraph_open" ||
          item?.type !== "list_item_open" ||
          !String(item.attrGet("class") ?? "")
            .split(/\s+/)
            .includes("task-list-item")
        ) {
          continue;
        }
        const checkbox = inline.children?.[0];
        if (
          checkbox?.type === "html_inline" &&
          GENERATED_TASK_CHECKBOX.test(checkbox.content)
        ) {
          checkbox.type = "mossmark_task_checkbox";
        }
      }
    },
  );

  // Native builds its sidebar outline from top-level Markdown headings. Mark
  // that same subset in the rendered preview so navigation never counts a
  // heading nested inside a blockquote/list, nor an empty CommonMark heading.
  // The value is generated locally and numeric, never copied from user HTML.
  renderer.core.ruler.push("mossmark-outline-indices", (state) => {
    let outlineIndex = 0;
    for (let index = 0; index < state.tokens.length; index += 1) {
      const opening = state.tokens[index];
      const inline = state.tokens[index + 1];
      if (
        opening?.type !== "heading_open" ||
        opening.level !== 0 ||
        inline?.type !== "inline" ||
        inline.content.trim() === ""
      ) {
        continue;
      }
      opening.attrSet("data-mossmark-outline-index", String(outlineIndex));
      outlineIndex += 1;
    }
  });

  renderer.renderer.rules.mossmark_task_checkbox = (tokens, index) => {
    const content = tokens[index]?.content ?? "";
    return GENERATED_TASK_CHECKBOX.test(content) ? content : escapeHTML(content);
  };

  const defaultFence = renderer.renderer.rules.fence;
  renderer.renderer.rules.fence = (tokens, index, options, env, self) => {
    const token = tokens[index];
    if (token?.info.trim().toLowerCase() === "mermaid") {
      return `<pre class="mermaid">${escapeHTML(token.content)}</pre>\n`;
    }
    if (defaultFence) {
      return defaultFence(tokens, index, options, env, self);
    }
    return self.renderToken(tokens, index, options);
  };

  const defaultLinkOpen =
    renderer.renderer.rules.link_open ??
    ((tokens, index, options, _env, self) => self.renderToken(tokens, index, options));
  renderer.renderer.rules.link_open = (tokens, index, options, env, self) => {
    tokens[index]?.attrSet("rel", "noreferrer noopener");
    return defaultLinkOpen(tokens, index, options, env, self);
  };

  renderer.renderer.rules.html_inline = (tokens, index) => {
    const token = tokens[index];
    if (!token) return "";
    return allowedInlineHTML(tokens).has(index)
      ? token.content
      : escapeHTML(token.content);
  };

  renderer.renderer.rules.html_block = (tokens, index) => {
    const token = tokens[index];
    if (!token) return "";
    return isSafeHTMLBlock(token.content)
      ? token.content
      : escapeHTML(token.content);
  };

  return renderer;
}

const renderer = createRenderer();

export function renderMarkdown(source: string): string {
  return renderer.render(sourceForPresentation(source));
}

export function renderStandaloneDocument(source: string, title = "Markdown"): string {
  const safeTitle = escapeHTML(title);
  return `<!doctype html>
<html lang="zh-CN">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>${safeTitle}</title>
</head>
<body class="markdown-body export-document">
${renderMarkdown(source)}
</body>
</html>`;
}
