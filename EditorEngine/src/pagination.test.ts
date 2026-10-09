import { describe, expect, it } from "vitest";
import { calculatePageBreaks } from "./pagination";

describe("calculatePageBreaks", () => {
  it("moves a page boundary above a text line instead of slicing it", () => {
    expect(
      calculatePageBreaks(1_800, 800, [{ top: 790, bottom: 812 }]),
    ).toEqual([0, 788, 1_588, 1_800]);
  });

  it("keeps a boundary in whitespace unchanged", () => {
    expect(
      calculatePageBreaks(1_700, 800, [{ top: 760, bottom: 780 }]),
    ).toEqual([0, 800, 1_600, 1_700]);
  });

  it("prioritizes the text line nearest the boundary inside a larger block", () => {
    expect(
      calculatePageBreaks(1_800, 800, [
        { top: 120, bottom: 1_100 },
        { top: 790, bottom: 812 },
      ]),
    ).toEqual([0, 788, 1_588, 1_800]);
  });

  it("does not stall on an indivisible item taller than half a page", () => {
    expect(
      calculatePageBreaks(1_700, 800, [{ top: 100, bottom: 900 }]),
    ).toEqual([0, 800, 1_600, 1_700]);
  });

  it("paginates a document longer than ten pages without slicing text lines", () => {
    const intervals = Array.from({ length: 120 }, (_, index) => ({
      top: 20 + index * 90,
      bottom: 44 + index * 90,
    }));
    const breaks = calculatePageBreaks(11_200, 800, intervals);

    expect(breaks.length).toBeGreaterThan(11);
    expect(breaks[0]).toBe(0);
    expect(breaks.at(-1)).toBe(11_200);
    for (const boundary of breaks.slice(1, -1)) {
      expect(
        intervals.some(({ top, bottom }) => top < boundary && boundary < bottom),
      ).toBe(false);
    }
  });
});
