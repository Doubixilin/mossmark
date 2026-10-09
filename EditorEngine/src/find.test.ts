import { describe, expect, it } from "vitest";
import { countOccurrences } from "./find";

describe("countOccurrences", () => {
  it("returns 0 for an empty query", () => {
    expect(countOccurrences("hello hello", "")).toBe(0);
  });

  it("counts case-insensitively by default", () => {
    expect(countOccurrences("Hello HELLO hello", "hello")).toBe(3);
  });

  it("respects caseSensitive", () => {
    expect(countOccurrences("Hello HELLO hello", "hello", true)).toBe(1);
    expect(countOccurrences("Hello HELLO hello", "Hello", true)).toBe(1);
  });

  it("counts non-overlapping occurrences", () => {
    expect(countOccurrences("aaaa", "aa")).toBe(2);
    expect(countOccurrences("aaa", "aa")).toBe(1);
  });

  it("treats the query literally, not as a regex", () => {
    expect(countOccurrences("a.b a*b ab", "a.b")).toBe(1);
    expect(countOccurrences("a.b a*b ab", "a*b")).toBe(1);
  });

  it("handles CJK text", () => {
    expect(countOccurrences("标题一标题二标题三", "标题")).toBe(3);
  });
});
