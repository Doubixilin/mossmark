import { afterEach, describe, expect, it, vi } from "vitest";
import { buildTocMarkup, nextPaintedLayout } from "./render-dom";

describe("buildTocMarkup", () => {
  it("builds a flat list for same-level headings", () => {
    const html = buildTocMarkup([
      { level: 1, id: "md-heading-0", text: "One" },
      { level: 1, id: "md-heading-1", text: "Two" },
    ]);
    expect(html).toBe(
      '<ul><li><a href="#md-heading-0">One</a></li>' +
        '<li><a href="#md-heading-1">Two</a></li></ul>',
    );
  });

  it("nests deeper levels inside the previous item", () => {
    const html = buildTocMarkup([
      { level: 1, id: "h0", text: "A" },
      { level: 2, id: "h1", text: "B" },
      { level: 3, id: "h2", text: "C" },
      { level: 2, id: "h3", text: "D" },
      { level: 1, id: "h4", text: "E" },
    ]);
    expect(html).toBe(
      '<ul><li><a href="#h0">A</a>' +
        '<ul><li><a href="#h1">B</a>' +
        '<ul><li><a href="#h2">C</a></li></ul></li>' +
        '<li><a href="#h3">D</a></li></ul></li>' +
        '<li><a href="#h4">E</a></li></ul>',
    );
  });

  it("handles skipped levels and escaped text", () => {
    const html = buildTocMarkup([
      { level: 3, id: "h0", text: "<Deep & Deeper>" },
    ]);
    expect(html).toBe(
      '<ul><li><a href="#h0">&lt;Deep &amp; Deeper&gt;</a></li></ul>',
    );
  });

  it("returns empty markup for no headings", () => {
    expect(buildTocMarkup([])).toBe("");
  });
});

describe("nextPaintedLayout", () => {
  afterEach(() => {
    vi.useRealTimers();
  });

  it("resolves true once the animation frames fire", async () => {
    await expect(
      nextPaintedLayout(1000, (callback) => callback()),
    ).resolves.toBe(true);
  });

  it("resolves false after the timeout when frames never fire", async () => {
    vi.useFakeTimers();
    let fireFrames: (() => void) | undefined;
    const painted = nextPaintedLayout(1000, (callback) => {
      fireFrames = callback;
    });
    await vi.advanceTimersByTimeAsync(1000);
    await expect(painted).resolves.toBe(false);
    // A frame arriving after the timeout must not flip the settled result.
    fireFrames?.();
    await expect(painted).resolves.toBe(false);
  });
});
