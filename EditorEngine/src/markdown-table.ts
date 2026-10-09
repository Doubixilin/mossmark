export type TableEditingCommand =
  | "add-row-before"
  | "add-row-after"
  | "add-column-before"
  | "add-column-after"
  | "delete-row"
  | "delete-column"
  | "align-left"
  | "align-center"
  | "align-right";

export interface TableEditResult {
  markdown: string;
  selection: number;
}

interface ParsedCell {
  text: string;
  start: number;
  end: number;
}

interface ParsedTable {
  startLine: number;
  separatorLine: number;
  endLine: number;
  column: number;
  activeBodyRow: number | undefined;
  header: string[];
  alignments: Array<"left" | "center" | "right" | undefined>;
  body: string[][];
}

function splitRow(line: string): ParsedCell[] {
  const segments: ParsedCell[] = [];
  let start = 0;
  let escaped = false;
  let codeFenceLength = 0;
  let index = 0;

  const append = (end: number) => {
    const raw = line.slice(start, end);
    const leading = raw.length - raw.trimStart().length;
    const trailing = raw.length - raw.trimEnd().length;
    segments.push({
      text: raw.trim(),
      start: start + leading,
      end: Math.max(start + leading, end - trailing),
    });
  };

  while (index < line.length) {
    const character = line[index];
    if (escaped) {
      escaped = false;
      index += 1;
      continue;
    }
    if (character === "\\") {
      escaped = true;
      index += 1;
      continue;
    }
    if (character === "`") {
      let runLength = 1;
      while (line[index + runLength] === "`") runLength += 1;
      if (codeFenceLength === 0) codeFenceLength = runLength;
      else if (codeFenceLength === runLength) codeFenceLength = 0;
      index += runLength;
      continue;
    }
    if (character === "|" && codeFenceLength === 0) {
      append(index);
      start = index + 1;
    }
    index += 1;
  }
  append(line.length);

  if (line.trimStart().startsWith("|") && segments[0]?.text === "") {
    segments.shift();
  }
  if (line.trimEnd().endsWith("|") && segments.at(-1)?.text === "") {
    segments.pop();
  }
  return segments;
}

function isSeparator(line: string): boolean {
  const cells = splitRow(line);
  return cells.length > 0 && cells.every(({ text }) => /^:?-{3,}:?$/.test(text));
}

function alignment(cell: string): "left" | "center" | "right" | undefined {
  const left = cell.startsWith(":");
  const right = cell.endsWith(":");
  if (left && right) return "center";
  if (right) return "right";
  if (left) return "left";
  return undefined;
}

function lineOffsets(markdown: string): number[] {
  const offsets = [0];
  for (let index = 0; index < markdown.length; index += 1) {
    if (markdown[index] === "\n") offsets.push(index + 1);
  }
  return offsets;
}

function findLine(offsets: number[], cursor: number): number {
  let low = 0;
  let high = offsets.length - 1;
  while (low <= high) {
    const middle = Math.floor((low + high) / 2);
    if (offsets[middle]! <= cursor) low = middle + 1;
    else high = middle - 1;
  }
  return Math.max(0, high);
}

function normalizeRow<T>(row: T[], columns: number, fill: T): T[] {
  return Array.from({ length: columns }, (_, index) => row[index] ?? fill);
}

function parseTable(markdown: string, cursor: number): ParsedTable | undefined {
  const lines = markdown.split("\n");
  const offsets = lineOffsets(markdown);
  const cursorLine = findLine(offsets, Math.max(0, Math.min(cursor, markdown.length)));

  for (let separatorLine = 1; separatorLine < lines.length; separatorLine += 1) {
    if (!isSeparator(lines[separatorLine]!)) continue;
    const startLine = separatorLine - 1;
    if (
      !lines[startLine]!.includes("|") &&
      !lines[separatorLine]!.includes("|")
    ) continue;
    let endLine = separatorLine;
    while (
      endLine + 1 < lines.length &&
      lines[endLine + 1]!.includes("|") &&
      lines[endLine + 1]!.trim() !== ""
    ) {
      endLine += 1;
    }
    if (cursorLine < startLine || cursorLine > endLine) continue;

    const activeCells = splitRow(lines[cursorLine]!);
    const relativeCursor = Math.max(0, cursor - offsets[cursorLine]!);
    let column = activeCells.findIndex(
      ({ start, end }) => start <= relativeCursor && relativeCursor <= end,
    );
    if (column < 0) {
      column = activeCells.findIndex(({ start }) => relativeCursor < start);
      if (column < 0) column = Math.max(0, activeCells.length - 1);
    }

    const header = splitRow(lines[startLine]!).map(({ text }) => text);
    const alignments = splitRow(lines[separatorLine]!).map(({ text }) => alignment(text));
    const body = lines
      .slice(separatorLine + 1, endLine + 1)
      .map((line) => splitRow(line).map(({ text }) => text));
    const columns = Math.max(
      1,
      header.length,
      alignments.length,
      ...body.map((row) => row.length),
    );

    return {
      startLine,
      separatorLine,
      endLine,
      column: Math.min(column, columns - 1),
      activeBodyRow:
        cursorLine > separatorLine ? cursorLine - separatorLine - 1 : undefined,
      header: normalizeRow(header, columns, ""),
      alignments: normalizeRow(alignments, columns, undefined),
      body: body.map((row) => normalizeRow(row, columns, "")),
    };
  }
  return undefined;
}

function renderTable(table: ParsedTable): string {
  const renderRow = (row: string[]) => `| ${row.join(" | ")} |`;
  const separator = table.alignments.map((value) => {
    if (value === "left") return ":---";
    if (value === "center") return ":---:";
    if (value === "right") return "---:";
    return "---";
  });
  return [
    renderRow(table.header),
    renderRow(separator),
    ...table.body.map(renderRow),
  ].join("\n");
}

export function editMarkdownTable(
  markdown: string,
  cursor: number,
  command: TableEditingCommand,
): TableEditResult | undefined {
  const table = parseTable(markdown, cursor);
  if (!table) return undefined;
  const column = table.column;

  switch (command) {
    case "add-row-before": {
      const insertion = table.activeBodyRow ?? 0;
      table.body.splice(insertion, 0, Array(table.header.length).fill(""));
      break;
    }
    case "add-row-after": {
      const insertion = table.activeBodyRow === undefined
        ? 0
        : table.activeBodyRow + 1;
      table.body.splice(insertion, 0, Array(table.header.length).fill(""));
      break;
    }
    case "delete-row":
      if (table.activeBodyRow === undefined) return undefined;
      table.body.splice(table.activeBodyRow, 1);
      break;
    case "add-column-before":
    case "add-column-after": {
      const insertion = column + (command === "add-column-after" ? 1 : 0);
      table.header.splice(insertion, 0, "");
      table.alignments.splice(insertion, 0, undefined);
      for (const row of table.body) row.splice(insertion, 0, "");
      break;
    }
    case "delete-column":
      if (table.header.length <= 1) return undefined;
      table.header.splice(column, 1);
      table.alignments.splice(column, 1);
      for (const row of table.body) row.splice(column, 1);
      break;
    case "align-left":
      table.alignments[column] = "left";
      break;
    case "align-center":
      table.alignments[column] = "center";
      break;
    case "align-right":
      table.alignments[column] = "right";
      break;
  }

  const offsets = lineOffsets(markdown);
  const from = offsets[table.startLine]!;
  const to = table.endLine + 1 < offsets.length
    ? offsets[table.endLine + 1]! - 1
    : markdown.length;
  const replacement = renderTable(table);
  return {
    markdown: markdown.slice(0, from) + replacement + markdown.slice(to),
    selection: Math.min(from + replacement.length, from + 2),
  };
}
