import { describe, expect, it } from "vitest";
import {
  analyzeMarkdownSafety,
  isSemanticallyEquivalent,
  semanticSignature,
} from "./safety";

describe("analyzeMarkdownSafety", () => {
  it("accepts common Markdown", () => {
    const report = analyzeMarkdownSafety("# 标题\n\n- [x] 已完成\n\n`code`");
    expect(report.safeForWysiwym).toBe(true);
    expect(report.issues).toEqual([]);
  });

  it("routes front matter to source mode", () => {
    const report = analyzeMarkdownSafety("---\ntitle: Test\n---\n\n# Heading");
    expect(report.safeForWysiwym).toBe(false);
    expect(report.issues.some((issue) => issue.code === "front-matter")).toBe(true);
  });

  it("routes raw HTML and comments to source mode", () => {
    const report = analyzeMarkdownSafety("<!-- keep -->\n<div>unsafe</div>");
    expect(report.safeForWysiwym).toBe(false);
    expect(report.issues.map((issue) => issue.code)).toEqual(
      expect.arrayContaining(["html-comment", "raw-html"]),
    );
  });

  it("flags real raw HTML", () => {
    const report = analyzeMarkdownSafety("# Title\n\n<div>unsafe</div>");
    expect(report.safeForWysiwym).toBe(false);
    expect(report.issues.some((issue) => issue.code === "raw-html")).toBe(true);
  });

  it("accepts CommonMark URI autolinks", () => {
    const report = analyzeMarkdownSafety("Links\n\n<https://example.com>");
    expect(report.safeForWysiwym).toBe(true);
    expect(report.issues).toEqual([]);
  });

  it("accepts CommonMark email autolinks", () => {
    const report = analyzeMarkdownSafety("Contact\n\n<user@example.com>");
    expect(report.safeForWysiwym).toBe(true);
    expect(report.issues).toEqual([]);
  });

  it("routes GitHub Alerts to source mode", () => {
    const report = analyzeMarkdownSafety("> [!NOTE]\n> Body text");
    expect(report.safeForWysiwym).toBe(false);
    expect(report.issues.some((issue) => issue.code === "github-alert")).toBe(true);
  });

  it("routes [TOC] markers to source mode", () => {
    for (const marker of ["[TOC]", "[toc]", "[[toc]]"]) {
      const report = analyzeMarkdownSafety(`# Title\n\n${marker}`);
      expect(report.safeForWysiwym).toBe(false);
      expect(report.issues.some((issue) => issue.code === "table-of-contents")).toBe(true);
    }
  });
});

describe("semanticSignature", () => {
  it("ignores harmless Markdown spelling differences", () => {
    expect(isSemanticallyEquivalent("# Title", "# Title\n")).toBe(true);
    expect(semanticSignature("**bold**")).toBe(semanticSignature("__bold__"));
  });

  it("detects semantic changes", () => {
    expect(isSemanticallyEquivalent("**bold**", "bold")).toBe(false);
  });

  it("shows why token equivalence alone cannot prove Crepe round trips", () => {
    // Markdown-it sees these extension markers as ordinary content. The
    // safety gate must therefore use explicit extension checks rather than
    // inferring Milkdown serializer behavior from this token stream.
    const types = (source: string) =>
      (JSON.parse(semanticSignature(source)) as Array<{ type: string }>).map(
        (token) => token.type,
      );
    expect(types("> [!NOTE]\n> body")).toEqual(types("> plain\n> body"));
  });

  it("parses [TOC] markers as ordinary paragraphs", () => {
    const types = (source: string) =>
      (JSON.parse(semanticSignature(source)) as Array<{ type: string }>).map(
        (token) => token.type,
      );
    expect(types("[TOC]")).toEqual(types("plain text"));
  });
});
