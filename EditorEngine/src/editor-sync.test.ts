import { describe, expect, it } from "vitest";
import {
  isCurrentGeneration,
  isCurrentImageImportContext,
  shouldAcceptWysiwymUpdate,
  shouldSynchronizeWysiwymTransaction,
  type ImageImportContext,
} from "./editor-sync";

describe("shouldAcceptWysiwymUpdate", () => {
  it("accepts a real edit from the synchronized visible revision", () => {
    expect(shouldAcceptWysiwymUpdate({
      mode: "wysiwym",
      editable: true,
      currentRevision: 7,
      synchronizedRevision: 7,
      currentMarkdown: "before",
      incomingMarkdown: "after",
    })).toBe(true);
  });

  it("rejects a late callback after source became authoritative", () => {
    expect(shouldAcceptWysiwymUpdate({
      mode: "source",
      editable: true,
      currentRevision: 8,
      synchronizedRevision: 7,
      currentMarkdown: "new source",
      incomingMarkdown: "stale rich text",
    })).toBe(false);
  });

  it("rejects callbacks after readonly is enabled or content is unchanged", () => {
    const base = {
      mode: "wysiwym" as const,
      currentRevision: 4,
      synchronizedRevision: 4,
      currentMarkdown: "same",
      incomingMarkdown: "changed",
    };
    expect(shouldAcceptWysiwymUpdate({ ...base, editable: false })).toBe(false);
    expect(shouldAcceptWysiwymUpdate({
      ...base,
      editable: true,
      incomingMarkdown: "same",
    })).toBe(false);
  });
});

describe("shouldSynchronizeWysiwymTransaction", () => {
  it("schedules an ordinary user document transaction", () => {
    expect(shouldSynchronizeWysiwymTransaction({
      docChanged: true,
      addToHistory: undefined,
      internalEditorUpdate: false,
    })).toBe(true);
  });

  it("ignores non-document, non-history, and internal replacement transactions", () => {
    expect(shouldSynchronizeWysiwymTransaction({
      docChanged: false,
      addToHistory: undefined,
      internalEditorUpdate: false,
    })).toBe(false);
    expect(shouldSynchronizeWysiwymTransaction({
      docChanged: true,
      addToHistory: false,
      internalEditorUpdate: false,
    })).toBe(false);
    expect(shouldSynchronizeWysiwymTransaction({
      docChanged: true,
      addToHistory: true,
      internalEditorUpdate: true,
    })).toBe(false);
  });
});

describe("isCurrentGeneration (stale load suppression)", () => {
  it("accepts only the call that still owns the current generation", () => {
    expect(isCurrentGeneration(3, 3)).toBe(true);
    expect(isCurrentGeneration(3, 4)).toBe(false);
  });

  it("a load superseded while awaiting applies no further effects", async () => {
    let loadGeneration = 0;
    const effects: string[] = [];
    const pendingRefreshes: Array<() => void> = [];

    // Mirrors load(): synchronous prologue, an awaited preview refresh, then
    // generation-checked side effects (mode switch, native post, outline).
    const load = async (document: string): Promise<void> => {
      const sequence = ++loadGeneration;
      effects.push(`begin:${document}`);
      await new Promise<void>((resolve) => pendingRefreshes.push(resolve));
      if (!isCurrentGeneration(sequence, loadGeneration)) return;
      effects.push(`commit:${document}`);
    };

    const stale = load("old");
    const current = load("new");
    pendingRefreshes[1]!(); // the newer load finishes its await first
    await current;
    pendingRefreshes[0]!(); // the stale load resumes late
    await stale;
    expect(effects).toEqual(["begin:old", "begin:new", "commit:new"]);
  });
});

describe("isCurrentImageImportContext", () => {
  const started: ImageImportContext = {
    revision: 11,
    mode: "wysiwym",
    editorGeneration: 3,
    editabilityGeneration: 2,
  };

  it("accepts only the unchanged editable WYSIWYM context", () => {
    expect(isCurrentImageImportContext(started, {
      ...started,
      editable: true,
    })).toBe(true);
  });

  it("rejects revision, mode, session, and editability changes", () => {
    expect(isCurrentImageImportContext(started, {
      ...started,
      revision: 12,
      editable: true,
    })).toBe(false);
    expect(isCurrentImageImportContext(started, {
      ...started,
      mode: "source",
      editable: true,
    })).toBe(false);
    expect(isCurrentImageImportContext(started, {
      ...started,
      editorGeneration: 4,
      editable: true,
    })).toBe(false);
    expect(isCurrentImageImportContext(started, {
      ...started,
      editabilityGeneration: 3,
      editable: false,
    })).toBe(false);
  });
});
