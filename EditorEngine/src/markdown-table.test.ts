import { describe, expect, it } from "vitest";
import { editMarkdownTable } from "./markdown-table";

const table = `Before

| Name | State |
| --- | :---: |
| Mossmark | Ready |

After`;

describe("editMarkdownTable", () => {
  it("adds a row relative to the active body row", () => {
    const cursor = table.indexOf("Ready");
    expect(editMarkdownTable(table, cursor, "add-row-before")?.markdown).toContain(
      "|  |  |\n| Mossmark | Ready |",
    );
  });

  it("adds and deletes columns without changing surrounding Markdown", () => {
    const cursor = table.indexOf("State");
    const added = editMarkdownTable(table, cursor, "add-column-after");
    expect(added?.markdown).toContain("| Name | State |  |");
    expect(added?.markdown.startsWith("Before\n\n")).toBe(true);
    expect(added?.markdown.endsWith("\n\nAfter")).toBe(true);

    const deleted = editMarkdownTable(table, cursor, "delete-column");
    expect(deleted?.markdown).toContain("| Name |");
    expect(deleted?.markdown).not.toContain("State");
  });

  it("changes only the active column alignment", () => {
    const cursor = table.indexOf("Name");
    expect(editMarkdownTable(table, cursor, "align-right")?.markdown).toContain(
      "| ---: | :---: |",
    );
  });

  it("preserves escaped and code-span pipes", () => {
    const markdown = `| A | B |
| --- | --- |
| one \\| two | \`x|y\` |`;
    const result = editMarkdownTable(markdown, markdown.indexOf("A"), "add-column-after");
    expect(result?.markdown).toContain("| one \\| two |  | `x|y` |");
  });

  it("does not edit text outside a valid GFM table", () => {
    expect(editMarkdownTable("A | B", 2, "add-row-after")).toBeUndefined();
    expect(editMarkdownTable("Heading\n---", 2, "add-column-after")).toBeUndefined();
  });
});
