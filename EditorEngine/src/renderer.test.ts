import { describe, expect, it } from "vitest";
import { renderMarkdown, renderStandaloneDocument } from "./renderer";

describe("renderMarkdown", () => {
  it("renders common extended syntax", () => {
    const html = renderMarkdown(
      "- [x] done\n\nA footnote[^1].\n\n[^1]: note\n\n$E = mc^2$",
    );
    expect(html).toContain("task-list-item");
    expect(html).toContain(
      '<input class="task-list-item-checkbox" checked="" disabled="" type="checkbox">',
    );
    expect(html).not.toContain("&lt;input");
    expect(html).not.toContain("<label");
    expect(html).not.toContain("&lt;label");
    expect(html).toContain("footnote-ref");
    expect(html).toContain("katex");
  });

  it("keeps task text and lookalike user HTML escaped", () => {
    const html = renderMarkdown(
      '- [ ] <img src=x onerror="alert(1)"> safe\n\nbefore <input class="task-list-item-checkbox" disabled="" type="checkbox"> after\n\n<input class="task-list-item-checkbox" onclick="alert(1)" type="checkbox">',
    );
    expect(html).toContain('type="checkbox"> &lt;img src=x onerror=&quot;alert(1)&quot;&gt; safe');
    expect(html).not.toContain("<img");
    expect(html).not.toContain('<input class="task-list-item-checkbox" onclick=');
    expect(html).toContain(
      'before &lt;input class=&quot;task-list-item-checkbox&quot; disabled=&quot;&quot; type=&quot;checkbox&quot;&gt; after',
    );
    expect(html).toContain("&lt;input class=&quot;task-list-item-checkbox&quot;");
  });

  it("renders rich task content once through normal Markdown rules", () => {
    const html = renderMarkdown("- [X] **bold** [link](https://example.com)");
    expect(html.match(/<strong>bold<\/strong>/g)).toHaveLength(1);
    expect(html.match(/>link<\/a>/g)).toHaveLength(1);
    expect(html).toContain('rel="noreferrer noopener"');
    expect(html).not.toContain("<label");
  });

  it("does not execute raw HTML", () => {
    const html = renderMarkdown('<script>alert("x")</script>');
    expect(html).not.toContain("<script>");
    expect(html).toContain("&lt;script&gt;");
  });

  it("omits front matter and comments from presentation output", () => {
    const html = renderMarkdown(
      "---\ntitle: Hidden\nauthor: Hidden\n---\n\n# Visible\n\n<!-- hidden -->",
    );
    expect(html).not.toContain("title: Hidden");
    expect(html).not.toContain("hidden --");
    expect(html).toContain(
      '<h1 data-mossmark-outline-index="0">Visible</h1>',
    );
  });

  it("indexes only non-empty top-level headings for preview navigation", () => {
    const html = renderMarkdown(
      "# Top\n\n> # Quoted\n\n- # Listed\n\n## B",
    );

    expect(html).toContain(
      '<h1 data-mossmark-outline-index="0">Top</h1>',
    );
    expect(html).toContain("<h1>Quoted</h1>");
    expect(html).toContain("<h1>Listed</h1>");
    expect(html).toContain(
      '<h2 data-mossmark-outline-index="1">B</h2>',
    );
    expect(html.match(/data-mossmark-outline-index=/g)).toHaveLength(2);
  });

  it("indexes setext headings and skips empty ATX headings", () => {
    const html = renderMarkdown("Setext\n======\n\n#\n\n## B");

    expect(html).toContain(
      '<h1 data-mossmark-outline-index="0">Setext</h1>',
    );
    expect(html).toContain("<h1></h1>");
    expect(html).toContain(
      '<h2 data-mossmark-outline-index="1">B</h2>',
    );
    expect(html.match(/data-mossmark-outline-index=/g)).toHaveLength(2);
  });

  it("allows only the supported attribute-free HTML subset", () => {
    const html = renderMarkdown(
      '<mark>safe</mark> <kbd>⌘K</kbd> <script>alert("x")</script>',
    );
    expect(html).toContain("<mark>safe</mark>");
    expect(html).toContain("<kbd>⌘K</kbd>");
    expect(html).not.toContain("<script>");
    expect(html).toContain("&lt;script&gt;");
  });

  it("keeps whitelisted tag spellings inside inline code escaped", () => {
    const html = renderMarkdown("`<mark>` and `<kbd>`");
    expect(html).toContain("<code>&lt;mark&gt;</code>");
    expect(html).toContain("<code>&lt;kbd&gt;</code>");
    expect(html).not.toContain("<mark>");
    expect(html).not.toContain("<kbd>");
  });

  it("keeps user-escaped entities as text", () => {
    const html = renderMarkdown("&lt;kbd&gt; stays text");
    expect(html).toContain("&lt;kbd&gt; stays text");
    expect(html).not.toContain("<kbd>");
  });

  it("does not allow whitelisted tags with attributes", () => {
    const html = renderMarkdown('<mark class="x">attr</mark>');
    expect(html).not.toContain("<mark");
    expect(html).not.toContain("</mark>");
    expect(html).toContain("&lt;mark class=&quot;x&quot;&gt;");
  });

  it("does not allow a stray whitelisted closing tag", () => {
    const html = renderMarkdown("text </mark> more");
    expect(html).not.toContain("</mark>");
    expect(html).toContain("&lt;/mark&gt;");
  });

  it("renders Mermaid source as an escaped diagram container", () => {
    const html = renderMarkdown("```mermaid\ngraph TD\nA-->B\n```");
    expect(html).toContain('<pre class="mermaid">');
    expect(html).toContain("A--&gt;B");
  });

  it("renders GitHub Alerts as callout containers", () => {
    const html = renderMarkdown("> [!WARNING]\n> Watch out.");
    expect(html).toContain('<div class="md-alert md-alert-warning">');
    expect(html).toContain("Watch out.");
    expect(html).not.toContain("[!WARNING]");
  });

  it("keeps alert text written on the marker line", () => {
    const html = renderMarkdown("> [!NOTE] First line stays.");
    expect(html).toContain('<div class="md-alert md-alert-note">');
    expect(html).toContain("First line stays.");
  });

  it("renders every alert kind with its own class", () => {
    for (const kind of ["NOTE", "TIP", "IMPORTANT", "WARNING", "CAUTION"]) {
      const html = renderMarkdown(`> [!${kind}]\n> body`);
      expect(html).toContain(`md-alert-${kind.toLowerCase()}`);
    }
  });

  it("keeps ordinary blockquotes and unknown markers untouched", () => {
    expect(renderMarkdown("> just a quote")).toContain("<blockquote>");
    const html = renderMarkdown("> [!UNKNOWN]\n> body");
    expect(html).toContain("<blockquote>");
    expect(html).not.toContain("md-alert");
  });

  it("closes nested blockquotes inside alerts correctly", () => {
    const html = renderMarkdown("> [!TIP]\n> outer\n> > inner quote\n> tail");
    expect(html).toContain('<div class="md-alert md-alert-tip">');
    expect(html).toContain("<blockquote>");
    expect(html).toContain("tail");
  });
});

describe("renderStandaloneDocument", () => {
  it("escapes the document title", () => {
    const html = renderStandaloneDocument("# Safe", "<unsafe>");
    expect(html).toContain("<title>&lt;unsafe&gt;</title>");
  });
});
