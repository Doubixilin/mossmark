import { markdown as markdownLanguage } from "@codemirror/lang-markdown";
import { HighlightStyle, syntaxHighlighting } from "@codemirror/language";
import { tags } from "@lezer/highlight";
import { Compartment, EditorState, Prec } from "@codemirror/state";
import { keymap } from "@codemirror/view";
import { Crepe, CrepeFeature } from "@milkdown/crepe";
import { editorViewCtx } from "@milkdown/kit/core";
import { Plugin } from "@milkdown/kit/prose/state";
import {
  createCodeBlockCommand,
  insertHrCommand,
  insertImageCommand,
  toggleEmphasisCommand,
  toggleInlineCodeCommand,
  toggleLinkCommand,
  toggleStrongCommand,
  wrapInBlockquoteCommand,
  wrapInBulletListCommand,
  wrapInHeadingCommand,
  wrapInOrderedListCommand,
} from "@milkdown/kit/preset/commonmark";
import {
  addColAfterCommand,
  addColBeforeCommand,
  addRowAfterCommand,
  addRowBeforeCommand,
  insertTableCommand,
  setAlignCommand,
  toggleStrikethroughCommand,
} from "@milkdown/kit/preset/gfm";
import { deleteColumn, deleteRow } from "@milkdown/kit/prose/tables";
import { $prose, callCommand } from "@milkdown/kit/utils";
import { replaceAll } from "@milkdown/utils";
import { basicSetup, EditorView } from "codemirror";
import {
  EDITOR_BRIDGE_PROTOCOL_VERSION,
  postToNative,
  type EditorDocumentSnapshot,
  type EditorMode,
} from "./bridge";
import {
  nextPaintedLayout,
  prepareMermaidForExport,
  renderInto,
  type ExportGraphic,
} from "./render-dom";
import { renderStandaloneDocument } from "./renderer";
import {
  analyzeMarkdownSafety,
  isSemanticallyEquivalent,
  type SafetyReport,
} from "./safety";
import {
  calculatePageBreaks,
  type PaginationInterval,
} from "./pagination";
import { editorLanguage, t } from "./i18n";
import { countOccurrences } from "./find";
import {
  editMarkdownTable,
  type TableEditingCommand,
} from "./markdown-table";
import {
  isCurrentGeneration,
  isCurrentImageImportContext,
  shouldAcceptWysiwymUpdate,
  shouldSynchronizeWysiwymTransaction,
  type ImageImportContext,
} from "./editor-sync";
import "./style.css";

interface LoadOptions {
  markdown: string;
  revision?: number;
  mode?: EditorMode;
  editable?: boolean;
}

interface MarkdownEditorAPI {
  load(options: LoadOptions): Promise<EditorDocumentSnapshot>;
  setMode(mode: EditorMode): Promise<EditorDocumentSnapshot>;
  getSnapshot(): EditorDocumentSnapshot;
  getExportHTML(title?: string): string;
  getSafetyReport(): SafetyReport;
  prepareForExport(pageHeightRatio?: number): Promise<
    EditorDocumentSnapshot & {
      exportGraphics: ExportGraphic[];
      expectedGraphicCount: number;
    }
  >;
  finishExport(mode: EditorMode): Promise<EditorDocumentSnapshot>;
  getPaginationBreaks(pageHeight: number): number[];
  applyFormatting(command: FormattingCommand, value?: string | number): boolean;
  editTable(command: TableEditingCommand): boolean;
  replaceAllText(query: string, replacement: string, caseSensitive?: boolean): number;
  scrollToHeading(index: number, line?: number): Promise<boolean>;
  setVisualPreference(preference: VisualPreference, enabled: boolean): void;
  setTypographyPreset(preset: TypographyPreset): void;
  setReadingMetrics(fontSize?: number, contentWidth?: number): void;
  setFullWidthLayout(enabled: boolean): void;
  setSpellCheck(enabled: boolean): void;
  setEditable(enabled: boolean): void;
  restoreScrollProgress(progress: number): void;
  mossmarkCountMatches(query: string, caseSensitive: boolean): number;
  mossmarkResolveImageImport(requestId: string, relativePath: string | null): boolean;
  focus(): void;
}

type FormattingCommand =
  | "bold"
  | "italic"
  | "strikethrough"
  | "inline-code"
  | "link"
  | "image"
  | "heading"
  | "bullet-list"
  | "ordered-list"
  | "blockquote"
  | "code-block"
  | "horizontal-rule"
  | "table";

type VisualPreference = "focus" | "typewriter";
type TypographyPreset = "quiet" | "paper" | "code";

declare global {
  interface Window {
    MarkdownEditor?: MarkdownEditorAPI;
    mossmarkResolveImageImport?: (
      requestId: string,
      relativePath: string | null,
    ) => boolean;
    mossmarkCountMatches?: (query: string, caseSensitive: boolean) => number;
    setReadingMetrics?: (fontSize?: number, contentWidth?: number) => void;
    setFullWidthLayout?: (enabled: boolean) => void;
    setSpellCheck?: (enabled: boolean) => void;
    restoreScrollProgress?: (progress: number) => void;
  }
}

function requiredElement<T extends HTMLElement>(id: string): T {
  const element = document.getElementById(id);
  if (!(element instanceof HTMLElement)) {
    throw new Error(`Editor surface #${id} is missing.`);
  }
  return element as T;
}

const wysiwymElement = requiredElement<HTMLElement>("wysiwym");
const sourceElement = requiredElement<HTMLElement>("source");
const previewElement = requiredElement<HTMLElement>("preview");

document.documentElement.lang = editorLanguage;
requiredElement<HTMLElement>("app").setAttribute("aria-label", t("aria.app"));
wysiwymElement.setAttribute("aria-label", t("aria.wysiwym"));
sourceElement.setAttribute("aria-label", t("aria.source"));
previewElement.setAttribute("aria-label", t("aria.preview"));

let currentMarkdown = "";
let currentMode: EditorMode = "preview";
let currentRevision = 0;
let internalEditorUpdate = false;
let pendingProgrammaticWysiwymMarkdown: string | undefined;
let wysiwymSynchronizedRevision: number | undefined;
let editingEnabled = true;
let editorGeneration = 0;
let editabilityGeneration = 0;
// Monotonic generations for long-running bridge calls: loadSequence marks the
// newest native load, modeSequence the newest setMode. A call that resumes
// from an await with a stale generation stops without side effects.
let loadSequence = 0;
let modeSequence = 0;
let previewRenderSequence = 0;
let previewDebounceTimer: number | undefined;
let focusModeEnabled = false;
let typewriterModeEnabled = false;
let readingScrollTop: number | undefined;
let readingPointerStart: { x: number; y: number } | undefined;
let lastReportedHeadingIndex = -2;
let headingUpdateFrame: number | undefined;
let exportViewState: {
  scrollTop: number;
  readingScrollTop: number | undefined;
} | undefined;

function snapshot(): EditorDocumentSnapshot {
  return {
    protocolVersion: EDITOR_BRIDGE_PROTOCOL_VERSION,
    revision: currentRevision,
    markdown: currentMarkdown,
    mode: currentMode,
  };
}

function setVisibleMode(mode: EditorMode): void {
  if (mode !== currentMode) editorGeneration += 1;
  wysiwymElement.classList.toggle("is-hidden", mode !== "wysiwym");
  sourceElement.classList.toggle("is-hidden", mode !== "source");
  previewElement.classList.toggle("is-hidden", mode !== "preview");
  currentMode = mode;
  scheduleHeadingUpdate();
}

interface ScrollPosition {
  top: number;
  progress: number;
}

function maximumScrollTop(): number {
  const height = Math.max(
    document.documentElement.scrollHeight,
    document.body.scrollHeight,
  );
  return Math.max(0, height - window.innerHeight);
}

function captureScrollPosition(): ScrollPosition {
  const maximum = maximumScrollTop();
  const top = Math.min(maximum, Math.max(0, window.scrollY));
  return {
    top,
    progress: maximum > 0 ? top / maximum : 0,
  };
}

// Restores a previously captured reading progress. The absolute offset is
// derived from the *current* layout, so this stays correct across font-size
// and viewport changes; switching back to preview mode reuses
// readingScrollTop the same way an interactive mode switch does.
function restoreScrollProgress(progress: number): void {
  if (!Number.isFinite(progress)) return;
  const clamped = Math.min(1, Math.max(0, progress));
  readingScrollTop = clamped * maximumScrollTop();
  if (currentMode === "preview") {
    window.scrollTo(0, Math.min(maximumScrollTop(), Math.max(0, readingScrollTop)));
  }
}

function nextLayout(): Promise<void> {
  return new Promise((resolve) => {
    let settled = false;
    const finish = (): void => {
      if (settled) return;
      settled = true;
      resolve();
    };
    requestAnimationFrame(() => requestAnimationFrame(finish));
    // Occluded or background WKWebViews throttle requestAnimationFrame
    // indefinitely; fall back to a timer so mode switches never hang.
    setTimeout(finish, 100);
  });
}

async function switchVisibleMode(mode: EditorMode): Promise<void> {
  if (mode === currentMode) return;

  const previousMode = currentMode;
  const previousPosition = captureScrollPosition();
  if (previousMode === "preview") {
    readingScrollTop = previousPosition.top;
  }

  setVisibleMode(mode);
  await nextLayout();

  const maximum = maximumScrollTop();
  const target = mode === "preview" && readingScrollTop !== undefined
    ? readingScrollTop
    : previousPosition.progress * maximum;
  window.scrollTo(0, Math.min(maximum, Math.max(0, target)));
}

async function refreshPreview(): Promise<void> {
  // A synchronous caller (mode switch, export, load) always renders the
  // latest markdown, so drop any debounced render that is still pending.
  if (previewDebounceTimer !== undefined) {
    clearTimeout(previewDebounceTimer);
    previewDebounceTimer = undefined;
  }
  const sequence = ++previewRenderSequence;
  try {
    await renderInto(previewElement, currentMarkdown);
    if (sequence === previewRenderSequence) scheduleHeadingUpdate();
  } catch (error) {
    if (sequence !== previewRenderSequence) return;
    postToNative("error", {
      message: error instanceof Error ? error.message : String(error),
      operation: "render-preview",
    });
  }
}

// Keystrokes re-render the whole preview, so debounce them; the actual
// render still goes through refreshPreview/previewRenderSequence.
function schedulePreviewRefresh(): void {
  if (previewDebounceTimer !== undefined) {
    clearTimeout(previewDebounceTimer);
  }
  previewDebounceTimer = window.setTimeout(() => {
    previewDebounceTimer = undefined;
    void refreshPreview();
  }, 200);
}

// Syntax colors and editor chrome read our own CSS variables, so the source
// view follows dark mode and the typography presets without a theme swap.
const sourceHighlightStyle = HighlightStyle.define([
  { tag: tags.heading, color: "var(--text-primary)", fontWeight: "700" },
  { tag: tags.strong, fontWeight: "700" },
  { tag: tags.emphasis, fontStyle: "italic" },
  { tag: tags.strikethrough, textDecoration: "line-through" },
  { tag: tags.quote, color: "var(--text-secondary)" },
  { tag: tags.link, color: "var(--accent)" },
  { tag: tags.url, color: "var(--text-secondary)" },
  { tag: tags.monospace, color: "var(--accent)" },
  { tag: [tags.keyword, tags.processingInstruction], color: "var(--accent)" },
  { tag: [tags.comment, tags.meta], color: "var(--text-secondary)" },
]);

const sourceEditorTheme = EditorView.theme({
  "&": {
    backgroundColor: "transparent",
    color: "var(--text-primary)",
  },
  ".cm-content": {
    caretColor: "var(--accent)",
  },
  "&.cm-focused .cm-cursor": {
    borderLeftColor: "var(--accent)",
  },
  ".cm-selectionBackground, &.cm-focused .cm-selectionBackground": {
    backgroundColor: "color-mix(in srgb, var(--accent) 22%, transparent)",
  },
  ".cm-activeLine": {
    backgroundColor: "color-mix(in srgb, var(--accent) 7%, transparent)",
  },
  ".cm-gutters": {
    color: "var(--text-secondary)",
    border: "none",
  },
});

const spellCheckCompartment = new Compartment();
const spellCheckExtension = (enabled: boolean) =>
  EditorView.contentAttributes.of({ spellcheck: String(enabled) });
const editableCompartment = new Compartment();

function prefersReducedMotion(): boolean {
  return window.matchMedia("(prefers-reduced-motion: reduce)").matches;
}

// Typewriter scrolling fires on every keystroke/selection change; coalesce
// bursts (e.g. holding an arrow key) into one scroll per 100ms window.
let typewriterScrollAt = 0;
let typewriterScrollTimer: number | undefined;

function scheduleTypewriterScroll(scroll: () => void): void {
  const elapsed = Date.now() - typewriterScrollAt;
  if (elapsed >= 100) {
    typewriterScrollAt = Date.now();
    scroll();
    return;
  }
  if (typewriterScrollTimer === undefined) {
    typewriterScrollTimer = window.setTimeout(() => {
      typewriterScrollTimer = undefined;
      typewriterScrollAt = Date.now();
      scroll();
    }, 100 - elapsed);
  }
}

const sourceView = new EditorView({
  parent: sourceElement,
  doc: currentMarkdown,
  extensions: [
    // The native find bar is the only search entry point; swallow Mod-F so
    // basicSetup's searchKeymap can never pop its own panel over it.
    Prec.highest(keymap.of([{ key: "Mod-f", run: () => true }])),
    basicSetup,
    markdownLanguage(),
    syntaxHighlighting(sourceHighlightStyle),
    sourceEditorTheme,
    EditorView.lineWrapping,
    editableCompartment.of([
      EditorView.editable.of(true),
      EditorState.readOnly.of(false),
    ]),
    spellCheckCompartment.of(spellCheckExtension(true)),
    EditorView.updateListener.of((update) => {
      if (update.docChanged && !internalEditorUpdate) {
        acceptChange(update.state.doc.toString(), "source");
      }
      if (typewriterModeEnabled && (update.docChanged || update.selectionSet)) {
        scheduleTypewriterScroll(() => {
          update.view.dispatch({
            effects: EditorView.scrollIntoView(update.state.selection.main.head, {
              y: "center",
            }),
          });
        });
      }
      if (update.docChanged || update.selectionSet || update.viewportChanged) {
        scheduleHeadingUpdate();
      }
    }),
  ],
});

// ImageBlock uploads: hand the file bytes to the native side, which saves
// the image next to the document and calls mossmarkResolveImageImport with
// the relative path (or null on failure, which rejects the Crepe upload).
const pendingImageImports = new Map<
  string,
  {
    resolve: (path: string) => void;
    reject: (error: Error) => void;
    context: ImageImportContext;
  }
>();

// The native file picker can import larger resources without base64 copies.
// Keep the WebKit script-message path lower because it simultaneously holds
// the File, a data URL, a JS string, an IPC copy, and a Swift String.
const maximumBridgedImageImportBytes = 25 * 1_024 * 1_024;

function currentImageImportContext(): ImageImportContext & { editable: boolean } {
  return {
    revision: currentRevision,
    mode: currentMode,
    editorGeneration,
    editabilityGeneration,
    editable: editingEnabled,
  };
}

async function fileToBase64(file: File): Promise<string> {
  return new Promise((resolve, reject) => {
    const reader = new FileReader();
    reader.onerror = () => reject(reader.error ?? new Error("Image read failed."));
    reader.onload = () => {
      const result = reader.result;
      if (typeof result !== "string") {
        reject(new Error("Image read failed."));
        return;
      }
      const separator = result.indexOf(",");
      if (separator < 0) {
        reject(new Error("Image encoding failed."));
        return;
      }
      resolve(result.slice(separator + 1));
    };
    reader.readAsDataURL(file);
  });
}

async function uploadImageToNative(file: File): Promise<string> {
  const context = currentImageImportContext();
  if (!isCurrentImageImportContext(context, context)) {
    throw new Error(t("warning.read-only"));
  }
  // Reject before allocating ArrayBuffer/base64 copies. The native side also
  // performs an encoded-length check before it decodes an untrusted message.
  if (file.size > maximumBridgedImageImportBytes) {
    throw new Error(t("image.paste-too-large"));
  }
  const requestId = crypto.randomUUID();
  const dataBase64 = await fileToBase64(file);
  if (!isCurrentImageImportContext(context, currentImageImportContext())) {
    throw new Error("Image import was canceled because the document changed.");
  }
  return new Promise<string>((resolve, reject) => {
    pendingImageImports.set(requestId, { resolve, reject, context });
    postToNative("import-image", {
      requestId,
      name: file.name || "image.png",
      dataBase64,
      mimeType: file.type || "image/png",
      revision: context.revision,
      mode: context.mode,
    });
  });
}

function mossmarkResolveImageImport(
  requestId: string,
  relativePath: string | null,
): boolean {
  const pending = pendingImageImports.get(requestId);
  if (!pending) return false;
  pendingImageImports.delete(requestId);
  if (relativePath === null) {
    pending.reject(new Error("Native image import failed."));
    return false;
  } else if (
    !isCurrentImageImportContext(
      pending.context,
      currentImageImportContext(),
    )
  ) {
    pending.reject(
      new Error("Image import was canceled because the document changed."),
    );
    return false;
  } else {
    pending.resolve(relativePath);
    return true;
  }
}

const crepe = new Crepe({
  root: wysiwymElement,
  defaultValue: currentMarkdown,
  features: {
    [CrepeFeature.AI]: false,
    [CrepeFeature.TopBar]: false,
  },
  featureConfigs: {
    [CrepeFeature.Placeholder]: {
      text: t("crepe.placeholder"),
    },
    [CrepeFeature.BlockEdit]: {
      textGroup: {
        label: t("crepe.slash.text-group"),
        text: { label: t("crepe.slash.text") },
        h1: { label: t("crepe.slash.h1") },
        h2: { label: t("crepe.slash.h2") },
        h3: { label: t("crepe.slash.h3") },
        h4: { label: t("crepe.slash.h4") },
        h5: { label: t("crepe.slash.h5") },
        h6: { label: t("crepe.slash.h6") },
        quote: { label: t("crepe.slash.quote") },
        divider: { label: t("crepe.slash.divider") },
      },
      listGroup: {
        label: t("crepe.slash.list-group"),
        bulletList: { label: t("crepe.slash.bullet-list") },
        orderedList: { label: t("crepe.slash.ordered-list") },
        taskList: { label: t("crepe.slash.task-list") },
      },
      advancedGroup: {
        label: t("crepe.slash.advanced-group"),
        image: { label: t("crepe.slash.image") },
        codeBlock: { label: t("crepe.slash.code-block") },
        table: { label: t("crepe.slash.table") },
        math: { label: t("crepe.slash.math") },
      },
    },
    [CrepeFeature.Toolbar]: {
      boldLabel: t("crepe.toolbar.bold"),
      italicLabel: t("crepe.toolbar.italic"),
      strikethroughLabel: t("crepe.toolbar.strikethrough"),
      codeLabel: t("crepe.toolbar.code"),
      linkLabel: t("crepe.toolbar.link"),
      latexLabel: t("crepe.toolbar.latex"),
    },
    [CrepeFeature.LinkTooltip]: {
      inputPlaceholder: t("crepe.link.input-placeholder"),
    },
    [CrepeFeature.ImageBlock]: {
      onUpload: uploadImageToNative,
      inlineUploadButton: t("crepe.image.upload"),
      blockUploadButton: t("crepe.image.upload-file"),
      inlineUploadPlaceholderText: t("crepe.image.upload-placeholder"),
      blockUploadPlaceholderText: t("crepe.image.upload-placeholder"),
      blockCaptionPlaceholderText: t("crepe.image.caption-placeholder"),
      blockConfirmButton: t("crepe.image.confirm"),
    },
    [CrepeFeature.CodeMirror]: {
      searchPlaceholder: t("crepe.code.search-placeholder"),
      noResultText: t("crepe.code.no-result"),
    },
  },
});

let immediateWysiwymSyncQueued = false;
function scheduleImmediateWysiwymSync(): void {
  if (immediateWysiwymSyncQueued) return;
  immediateWysiwymSyncQueued = true;
  queueMicrotask(() => {
    immediateWysiwymSyncQueued = false;
    flushWysiwymChange();
  });
}

// Milkdown's listener serializes Markdown on a 200 ms debounce. Observe the
// underlying ProseMirror transactions as well so each user edit reaches the
// native FileDocument before the next keyboard/window event. The microtask runs
// after ProseMirror has installed the final state (including appended plugin
// transactions), and multiple transactions in one event are coalesced.
const immediateWysiwymSyncPlugin = $prose(() =>
  new Plugin({
    appendTransaction: (transactions) => {
      if (transactions.some((transaction) =>
        shouldSynchronizeWysiwymTransaction({
          docChanged: transaction.docChanged,
          addToHistory: transaction.getMeta("addToHistory"),
          internalEditorUpdate,
        })
      )) {
        scheduleImmediateWysiwymSync();
      }
      return null;
    },
  })
);
crepe.editor.use(immediateWysiwymSyncPlugin);

crepe.on((listener) => {
  listener.markdownUpdated((_ctx, markdown, previousMarkdown) => {
    if (internalEditorUpdate || markdown === previousMarkdown) return;
    if (!shouldAcceptWysiwymUpdate({
      mode: currentMode,
      editable: editingEnabled,
      currentRevision,
      synchronizedRevision: wysiwymSynchronizedRevision,
      currentMarkdown,
      incomingMarkdown: markdown,
    })) return;
    if (pendingProgrammaticWysiwymMarkdown !== undefined) {
      const expected = pendingProgrammaticWysiwymMarkdown;
      pendingProgrammaticWysiwymMarkdown = undefined;
      // Milkdown debounces this callback, so the synchronous
      // internalEditorUpdate flag has already been cleared by the time a
      // programmatic replaceAll is reported. Ignore only the exact serialized
      // value we just installed; a real user edit must still be accepted.
      if (markdown === expected) return;
    }
    acceptChange(markdown, "wysiwym");
  });
  listener.blur(() => {
    flushWysiwymChange();
  });
});

function setSource(markdown: string): void {
  if (sourceView.state.doc.toString() === markdown) return;
  internalEditorUpdate = true;
  try {
    sourceView.dispatch({
      changes: { from: 0, to: sourceView.state.doc.length, insert: markdown },
    });
  } finally {
    internalEditorUpdate = false;
  }
}

function setWysiwym(markdown: string): void {
  if (crepe.getMarkdown() === markdown) {
    pendingProgrammaticWysiwymMarkdown = undefined;
    wysiwymSynchronizedRevision = currentRevision;
    return;
  }
  internalEditorUpdate = true;
  try {
    crepe.editor.action(replaceAll(markdown, true));
    pendingProgrammaticWysiwymMarkdown = crepe.getMarkdown();
    wysiwymSynchronizedRevision = currentRevision;
  } finally {
    internalEditorUpdate = false;
  }
}

function flushWysiwymChange(): boolean {
  const markdown = crepe.getMarkdown();
  if (!shouldAcceptWysiwymUpdate({
    mode: currentMode,
    editable: editingEnabled,
    currentRevision,
    synchronizedRevision: wysiwymSynchronizedRevision,
    currentMarkdown,
    incomingMarkdown: markdown,
  })) return false;

  if (pendingProgrammaticWysiwymMarkdown === markdown) {
    pendingProgrammaticWysiwymMarkdown = undefined;
    return false;
  }
  pendingProgrammaticWysiwymMarkdown = undefined;
  acceptChange(markdown, "wysiwym");
  return true;
}

function setEditable(enabled: boolean): void {
  if (!enabled && editingEnabled) flushWysiwymChange();
  if (editingEnabled !== enabled) editabilityGeneration += 1;
  editingEnabled = enabled;
  sourceView.dispatch({
    effects: editableCompartment.reconfigure([
      EditorView.editable.of(enabled),
      EditorState.readOnly.of(!enabled),
    ]),
  });
  sourceElement.setAttribute("aria-readonly", String(!enabled));
  wysiwymElement.setAttribute("aria-readonly", String(!enabled));
  // Use Crepe's public readonly state so its feature plugins and placeholders
  // agree with the ProseMirror view's editability.
  crepe.setReadonly(!enabled);
}

function acceptChange(
  markdown: string,
  origin: "source" | "wysiwym" | "api",
): void {
  if (markdown === currentMarkdown) return;
  currentMarkdown = markdown;
  currentRevision += 1;

  // Keep only the visible editing surface synchronized. Crepe serializes the
  // whole document and may normalize Markdown spelling, so populate it lazily
  // when the user actually requests WYSIWYM mode.
  if (origin === "wysiwym") {
    setSource(markdown);
    wysiwymSynchronizedRevision = currentRevision;
  } else if (origin === "api") {
    setSource(markdown);
    if (currentMode === "wysiwym") setWysiwym(markdown);
  }

  void schedulePreviewRefresh();
  postToNative("change", snapshot());
  scheduleHeadingUpdate();
}

function reportUnsafeMode(report: SafetyReport): void {
  const issue = report.issues[0];
  const line = issue?.line;
  const message = issue === undefined
    ? t("warning.unsafe")
    : line === undefined
      ? t("warning.unsafe-detail", { reason: issue.message })
      : t("warning.unsafe-detail-at-line", {
          line: String(line),
          reason: issue.message,
        });
  postToNative("warning", {
    code: "wysiwym-unsafe",
    message,
    issues: report.issues,
  });
}

function evaluateWysiwymSafety(markdown: string): SafetyReport {
  const report = analyzeMarkdownSafety(markdown);
  if (!report.safeForWysiwym) return report;

  setWysiwym(markdown);
  const serialized = crepe.getMarkdown();
  if (!isSemanticallyEquivalent(markdown, serialized)) {
    return {
      safeForWysiwym: false,
      issues: [
        {
          code: "serializer-round-trip",
          message: t("warning.roundtrip"),
        },
      ],
    };
  }
  return report;
}

async function load(options: LoadOptions): Promise<EditorDocumentSnapshot> {
  // A native load establishes a new authoritative document generation. Any
  // delayed callback or upload from the previous generation must be ignored.
  const sequence = ++loadSequence;
  editorGeneration += 1;
  wysiwymSynchronizedRevision = undefined;
  pendingProgrammaticWysiwymMarkdown = undefined;
  currentMarkdown = options.markdown;
  currentRevision = options.revision ?? 0;
  setEditable(options.editable ?? true);
  setSource(currentMarkdown);
  readingScrollTop = 0;
  setVisibleMode("preview");
  await refreshPreview();
  // A newer load superseded this one while awaiting; its state is
  // authoritative now, so stop without touching mode/outline/native.
  if (!isCurrentGeneration(sequence, loadSequence)) return snapshot();

  const requestedMode = options.mode ?? "preview";
  if (requestedMode === "wysiwym") {
    const report = evaluateWysiwymSafety(currentMarkdown);
    if (!report.safeForWysiwym) {
      setVisibleMode("source");
      reportUnsafeMode(report);
    } else {
      setVisibleMode("wysiwym");
    }
  } else {
    setVisibleMode(requestedMode);
  }

  postToNative("mode", { mode: currentMode });
  await nextLayout();
  if (!isCurrentGeneration(sequence, loadSequence)) return snapshot();
  reportCurrentHeading(true);
  return snapshot();
}

async function setMode(mode: EditorMode): Promise<EditorDocumentSnapshot> {
  // Superseded by a newer setMode or by a load while awaiting: stop so a
  // late completion cannot flip the mode or post a stale mode to native.
  const sequence = ++modeSequence;
  const loadAtStart = loadSequence;
  const isStale = (): boolean =>
    !isCurrentGeneration(sequence, modeSequence) ||
    !isCurrentGeneration(loadAtStart, loadSequence);
  // Milkdown's markdownUpdated listener is debounced by 200 ms. Capture the
  // current ProseMirror document before hiding/re-entering the surface so a
  // delayed callback cannot lose or later overwrite this edit.
  if (currentMode === "wysiwym") flushWysiwymChange();
  if (mode === "wysiwym") {
    const report = evaluateWysiwymSafety(currentMarkdown);
    if (!report.safeForWysiwym) {
      await switchVisibleMode("source");
      if (isStale()) return snapshot();
      reportUnsafeMode(report);
      postToNative("mode", { mode: currentMode });
      return snapshot();
    }
  }

  if (mode === "preview") {
    await refreshPreview();
    if (isStale()) return snapshot();
    await switchVisibleMode("preview");
  } else {
    await switchVisibleMode(mode);
  }
  if (isStale()) return snapshot();
  postToNative("mode", { mode: currentMode });
  scheduleHeadingUpdate();
  return snapshot();
}

function focusEditor(): void {
  if (currentMode === "source") {
    sourceView.focus();
    return;
  }
  if (currentMode === "wysiwym") {
    wysiwymElement.querySelector<HTMLElement>(".ProseMirror")?.focus();
  }
}

function replaceSourceSelection(
  prefix: string,
  suffix: string,
  placeholder: string,
  selectBody = true,
): boolean {
  const selection = sourceView.state.selection.main;
  const selected = sourceView.state.sliceDoc(selection.from, selection.to);
  const body = selected || placeholder;
  const inserted = `${prefix}${body}${suffix}`;
  const insertionEnd = selection.from + inserted.length;
  sourceView.dispatch({
    changes: {
      from: selection.from,
      to: selection.to,
      insert: inserted,
    },
    selection: selectBody
      ? {
          anchor: selection.from + prefix.length,
          head: selection.from + prefix.length + body.length,
        }
      : { anchor: insertionEnd },
    scrollIntoView: true,
  });
  sourceView.focus();
  return true;
}

function prefixSourceLines(prefix: string, numbered = false): boolean {
  const selection = sourceView.state.selection.main;
  const firstLine = sourceView.state.doc.lineAt(selection.from);
  const lastLine = sourceView.state.doc.lineAt(selection.to);
  const original = sourceView.state.sliceDoc(firstLine.from, lastLine.to);
  const replacement = original
    .split("\n")
    .map((line, index) => `${numbered ? `${index + 1}. ` : prefix}${line}`)
    .join("\n");
  sourceView.dispatch({
    changes: { from: firstLine.from, to: lastLine.to, insert: replacement },
    selection: { anchor: firstLine.from, head: firstLine.from + replacement.length },
    scrollIntoView: true,
  });
  sourceView.focus();
  return true;
}

function headingSource(level: number): boolean {
  const selection = sourceView.state.selection.main;
  const firstLine = sourceView.state.doc.lineAt(selection.from);
  const lastLine = sourceView.state.doc.lineAt(selection.to);
  const original = sourceView.state.sliceDoc(firstLine.from, lastLine.to);
  const prefix = `${"#".repeat(Math.max(1, Math.min(6, level)))} `;
  const replacement = original
    .split("\n")
    .map((line) => prefix + line.replace(/^#{1,6}\s+/, ""))
    .join("\n");
  sourceView.dispatch({
    changes: { from: firstLine.from, to: lastLine.to, insert: replacement },
    selection: { anchor: firstLine.from, head: firstLine.from + replacement.length },
    scrollIntoView: true,
  });
  sourceView.focus();
  return true;
}

function applySourceFormatting(
  command: FormattingCommand,
  value?: string | number,
): boolean {
  switch (command) {
    case "bold":
      return replaceSourceSelection("**", "**", t("placeholder.bold"));
    case "italic":
      return replaceSourceSelection("*", "*", t("placeholder.italic"));
    case "strikethrough":
      return replaceSourceSelection("~~", "~~", t("placeholder.strikethrough"));
    case "inline-code":
      return replaceSourceSelection("`", "`", "code");
    case "link":
      return replaceSourceSelection("[", `](${String(value ?? "https://")})`, t("placeholder.link"));
    case "image":
      return replaceSourceSelection(
        "![",
        `](${String(value ?? "image.png")})`,
        t("placeholder.image-description"),
        false,
      );
    case "heading":
      return headingSource(Number(value ?? 1));
    case "bullet-list":
      return prefixSourceLines("- ");
    case "ordered-list":
      return prefixSourceLines("", true);
    case "blockquote":
      return prefixSourceLines("> ");
    case "code-block":
      return replaceSourceSelection("```\n", "\n```", "code");
    case "horizontal-rule":
      return replaceSourceSelection("\n---\n", "", "");
    case "table":
      return replaceSourceSelection(
        `\n| ${t("table.column1")} | ${t("table.column2")} |\n| --- | --- |\n| `,
        ` | ${t("table.value")} |\n`,
        t("table.value"),
      );
  }
}

function applyWysiwymFormatting(
  command: FormattingCommand,
  value?: string | number,
): boolean {
  switch (command) {
    case "bold":
      crepe.editor.action(callCommand(toggleStrongCommand.key));
      break;
    case "italic":
      crepe.editor.action(callCommand(toggleEmphasisCommand.key));
      break;
    case "strikethrough":
      crepe.editor.action(callCommand(toggleStrikethroughCommand.key));
      break;
    case "inline-code":
      crepe.editor.action(callCommand(toggleInlineCodeCommand.key));
      break;
    case "link":
      crepe.editor.action(
        callCommand(toggleLinkCommand.key, { href: String(value ?? "https://") }),
      );
      break;
    case "image":
      crepe.editor.action(
        callCommand(insertImageCommand.key, {
          src: String(value ?? "image.png"),
          alt: t("placeholder.image"),
        }),
      );
      break;
    case "heading":
      crepe.editor.action(
        callCommand(wrapInHeadingCommand.key, Number(value ?? 1)),
      );
      break;
    case "bullet-list":
      crepe.editor.action(callCommand(wrapInBulletListCommand.key));
      break;
    case "ordered-list":
      crepe.editor.action(callCommand(wrapInOrderedListCommand.key));
      break;
    case "blockquote":
      crepe.editor.action(callCommand(wrapInBlockquoteCommand.key));
      break;
    case "code-block":
      crepe.editor.action(callCommand(createCodeBlockCommand.key));
      break;
    case "horizontal-rule":
      crepe.editor.action(callCommand(insertHrCommand.key));
      break;
    case "table":
      crepe.editor.action(callCommand(insertTableCommand.key, { row: 3, col: 3 }));
      break;
  }
  focusEditor();
  return true;
}

function applyFormatting(
  command: FormattingCommand,
  value?: string | number,
): boolean {
  if (!editingEnabled || currentMode === "preview") return false;
  return currentMode === "source"
    ? applySourceFormatting(command, value)
    : applyWysiwymFormatting(command, value);
}

function applySourceTableEditing(command: TableEditingCommand): boolean {
  const selection = sourceView.state.selection.main;
  const result = editMarkdownTable(
    sourceView.state.doc.toString(),
    selection.head,
    command,
  );
  if (!result) return false;
  sourceView.dispatch({
    changes: {
      from: 0,
      to: sourceView.state.doc.length,
      insert: result.markdown,
    },
    selection: { anchor: result.selection },
    scrollIntoView: true,
  });
  sourceView.focus();
  return true;
}

function applyWysiwymTableEditing(command: TableEditingCommand): boolean {
  let edited = false;
  switch (command) {
    case "add-row-before":
      edited = crepe.editor.action(callCommand(addRowBeforeCommand.key));
      break;
    case "add-row-after":
      edited = crepe.editor.action(callCommand(addRowAfterCommand.key));
      break;
    case "add-column-before":
      edited = crepe.editor.action(callCommand(addColBeforeCommand.key));
      break;
    case "add-column-after":
      edited = crepe.editor.action(callCommand(addColAfterCommand.key));
      break;
    case "delete-row":
      edited = crepe.editor.action((ctx) => {
        const view = ctx.get(editorViewCtx);
        return deleteRow(view.state, (transaction) => view.dispatch(transaction));
      });
      break;
    case "delete-column":
      edited = crepe.editor.action((ctx) => {
        const view = ctx.get(editorViewCtx);
        return deleteColumn(view.state, (transaction) => view.dispatch(transaction));
      });
      break;
    case "align-left":
      edited = crepe.editor.action(callCommand(setAlignCommand.key, "left"));
      break;
    case "align-center":
      edited = crepe.editor.action(callCommand(setAlignCommand.key, "center"));
      break;
    case "align-right":
      edited = crepe.editor.action(callCommand(setAlignCommand.key, "right"));
      break;
  }
  if (edited) focusEditor();
  return edited;
}

function editTable(command: TableEditingCommand): boolean {
  if (!editingEnabled || currentMode === "preview") return false;
  return currentMode === "source"
    ? applySourceTableEditing(command)
    : applyWysiwymTableEditing(command);
}

function replaceAllText(
  query: string,
  replacement: string,
  caseSensitive = false,
): number {
  if (!editingEnabled || !query) return 0;
  if (currentMode === "wysiwym") flushWysiwymChange();
  const escaped = query.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  const expression = new RegExp(escaped, caseSensitive ? "g" : "gi");
  const matches = currentMarkdown.match(expression)?.length ?? 0;
  if (matches === 0) return 0;
  acceptChange(currentMarkdown.replace(expression, replacement), "api");
  return matches;
}

function viewportBounds(): { top: number; bottom: number } {
  const viewport = window.visualViewport;
  const top = viewport?.offsetTop ?? 0;
  return { top, bottom: top + (viewport?.height ?? window.innerHeight) };
}

function renderedOutlineHeadings(root: HTMLElement): HTMLElement[] {
  if (root === previewElement) {
    return Array.from(
      root.querySelectorAll<HTMLElement>("[data-mossmark-outline-index]"),
    );
  }
  const proseMirror = root.querySelector<HTMLElement>(".ProseMirror");
  if (!proseMirror) return [];
  return Array.from(proseMirror.children).filter(
    (element): element is HTMLElement =>
      element instanceof HTMLElement && /^H[1-6]$/.test(element.tagName),
  );
}

function elementIntersectsViewport(element: HTMLElement): boolean {
  const rect = element.getBoundingClientRect();
  const viewport = viewportBounds();
  return rect.height > 0 && rect.bottom > viewport.top && rect.top < viewport.bottom;
}

function sourcePositionIsVisible(position: number): boolean {
  const rect = sourceView.coordsAtPos(position);
  if (!rect) return false;
  const scroller = sourceView.scrollDOM.getBoundingClientRect();
  const viewport = viewportBounds();
  const visibleTop = Math.max(scroller.top, viewport.top);
  const visibleBottom = Math.min(scroller.bottom, viewport.bottom);
  return rect.bottom > visibleTop && rect.top < visibleBottom;
}

async function scrollToHeading(index: number, line?: number): Promise<boolean> {
  const loadAtStart = loadSequence;
  for (let attempt = 0; attempt < 8; attempt += 1) {
    if (!isCurrentGeneration(loadAtStart, loadSequence)) return false;

    if (currentMode === "source") {
      let position: number | undefined;
      if (line !== undefined) {
        if (!Number.isInteger(line) || line < 1 || line > sourceView.state.doc.lines) {
          return false;
        }
        position = sourceView.state.doc.line(line).from;
      } else {
        position = sourceHeadingPositions()[index];
      }
      if (position === undefined) return false;
      if (sourceElement.classList.contains("is-hidden") || !sourceView.inView) {
        await nextPaintedLayout(180);
        continue;
      }

      sourceView.dispatch({
        selection: { anchor: position },
        effects: EditorView.scrollIntoView(position, { y: "center" }),
      });
      sourceView.requestMeasure();
      if (!(await nextPaintedLayout(180))) continue;
      if (!isCurrentGeneration(loadAtStart, loadSequence)) return false;
      if (!sourcePositionIsVisible(position)) continue;
    } else {
      const root = currentMode === "wysiwym" ? wysiwymElement : previewElement;
      if (root.classList.contains("is-hidden")) {
        await nextPaintedLayout(180);
        continue;
      }
      const heading = renderedOutlineHeadings(root)[index];
      if (!heading) return false;
      heading.scrollIntoView({ behavior: "auto", block: "center" });
      if (!(await nextPaintedLayout(180))) continue;
      if (!isCurrentGeneration(loadAtStart, loadSequence)) return false;
      if (!elementIntersectsViewport(heading)) continue;
    }

    // Report success only after layout confirms the requested target is
    // visible. This is deliberately stronger than merely finding the target
    // or enqueueing CodeMirror's scroll effect.
    postToNative("outline", { index });
    lastReportedHeadingIndex = index;
    return true;
  }
  return false;
}

// Heading positions only change with the document, so cache them per
// CodeMirror document object instead of rescanning every line on each
// scroll/selection frame.
let cachedHeadingDoc: unknown;
let cachedHeadingPositions: number[] = [];

function computeSourceHeadingPositions(): number[] {
  const positions: number[] = [];
  let insideHTMLComment = false;
  const visibleLines = Array.from(
    { length: sourceView.state.doc.lines },
    (_, index) => {
      const line = sourceView.state.doc.line(index + 1);
      let remainder = line.text;
      let visible = "";
      while (remainder !== "") {
        if (insideHTMLComment) {
          const end = remainder.indexOf("-->");
          if (end < 0) break;
          remainder = remainder.slice(end + 3);
          insideHTMLComment = false;
        } else {
          const start = remainder.indexOf("<!--");
          if (start < 0) {
            visible += remainder;
            break;
          }
          visible += remainder.slice(0, start);
          remainder = remainder.slice(start + 4);
          insideHTMLComment = true;
        }
      }
      return { line, text: visible };
    },
  );
  let fence: { marker: "`" | "~"; length: number } | undefined;
  const firstLine = visibleLines[0]?.text.trim() ?? "";
  let inFrontMatter = firstLine === "---";

  for (let index = 0; index < visibleLines.length; index += 1) {
    const entry = visibleLines[index]!;
    const lineNumber = index + 1;
    const trimmed = entry.text.trim();
    if (inFrontMatter) {
      if (lineNumber > 1 && (trimmed === "---" || trimmed === "...")) {
        inFrontMatter = false;
      }
      continue;
    }
    const fenceMatch = /^( {0,3})(`{3,}|~{3,})(.*)$/.exec(entry.text);
    if (fenceMatch) {
      const run = fenceMatch[2]!;
      const marker = run[0] as "`" | "~";
      if (fence === undefined) {
        fence = { marker, length: run.length };
      } else if (
        marker === fence.marker &&
        run.length >= fence.length &&
        fenceMatch[3]!.trim() === ""
      ) {
        fence = undefined;
      }
      continue;
    }
    if (fence !== undefined) continue;
    if (/^\s{0,3}#{1,6}\s+(.+?)\s*#*\s*$/.test(entry.text)) {
      positions.push(entry.line.from);
      continue;
    }
    if (trimmed === "" || index + 1 >= visibleLines.length) continue;
    const nextLine = visibleLines[index + 1]!.text;
    if (/^\s*(=+|-+)\s*$/.test(nextLine)) positions.push(entry.line.from);
  }
  return positions;
}

function sourceHeadingPositions(): number[] {
  const doc = sourceView.state.doc;
  if (cachedHeadingDoc !== doc) {
    cachedHeadingDoc = doc;
    cachedHeadingPositions = computeSourceHeadingPositions();
  }
  return cachedHeadingPositions;
}

function currentSourceHeadingIndex(): number {
  const visibleOffset = sourceView.visibleRanges[0]?.from
    ?? sourceView.state.selection.main.head;
  let current = -1;
  for (const [index, position] of sourceHeadingPositions().entries()) {
    if (position > visibleOffset) break;
    current = index;
  }
  return current;
}

function currentRenderedHeadingIndex(): number {
  const root = currentMode === "wysiwym" ? wysiwymElement : previewElement;
  const headings = renderedOutlineHeadings(root);
  if (headings.length === 0) return -1;
  const threshold = Math.min(180, window.innerHeight * 0.22);
  let current = -1;
  headings.forEach((heading, index) => {
    if (heading.getBoundingClientRect().top <= threshold) current = index;
  });
  if (current >= 0) return current;
  return headings.findIndex((heading) => heading.getBoundingClientRect().bottom > 0);
}

function reportCurrentHeading(force = false): void {
  const index = currentMode === "source"
    ? currentSourceHeadingIndex()
    : currentRenderedHeadingIndex();
  if (!force && index === lastReportedHeadingIndex) return;
  lastReportedHeadingIndex = index;
  postToNative("outline", { index });
}

function scheduleHeadingUpdate(): void {
  if (headingUpdateFrame !== undefined) return;
  headingUpdateFrame = requestAnimationFrame(() => {
    headingUpdateFrame = undefined;
    reportCurrentHeading();
  });
}

// Reports the reading (preview) scroll progress to native once scrolling
// settles, so the host can persist the per-document reading position live
// instead of racing the view's teardown to capture it.
let scrollProgressTimer: number | undefined;

function scheduleScrollProgressReport(): void {
  if (currentMode !== "preview") return;
  if (scrollProgressTimer !== undefined) clearTimeout(scrollProgressTimer);
  scrollProgressTimer = window.setTimeout(() => {
    scrollProgressTimer = undefined;
    postToNative("scroll-progress", {
      progress: captureScrollPosition().progress,
    });
  }, 350);
}

function updateFocusedBlock(): void {
  wysiwymElement.querySelectorAll(".is-focus-block").forEach((element) => {
    element.classList.remove("is-focus-block");
  });
  if (!focusModeEnabled && !typewriterModeEnabled) return;
  const selection = document.getSelection();
  const anchor = selection?.anchorNode;
  const element = anchor instanceof Element ? anchor : anchor?.parentElement;
  const editor = element?.closest(".ProseMirror");
  if (!editor) return;
  let block = element;
  while (block?.parentElement && block.parentElement !== editor) {
    block = block.parentElement;
  }
  block?.classList.add("is-focus-block");
  if (typewriterModeEnabled && block) {
    const target = block;
    scheduleTypewriterScroll(() => {
      target.scrollIntoView({
        block: "center",
        behavior: prefersReducedMotion() ? "auto" : "smooth",
      });
    });
  }
}

function setVisualPreference(
  preference: VisualPreference,
  enabled: boolean,
): void {
  if (preference === "focus") {
    focusModeEnabled = enabled;
    document.body.classList.toggle("focus-mode", enabled);
  } else {
    typewriterModeEnabled = enabled;
    document.body.classList.toggle("typewriter-mode", enabled);
  }
  updateFocusedBlock();
}

function setTypographyPreset(preset: TypographyPreset): void {
  const accepted: TypographyPreset = preset === "paper" || preset === "code"
    ? preset
    : "quiet";
  document.documentElement.dataset.typography = accepted;
}

function setReadingMetrics(fontSize?: number, contentWidth?: number): void {
  if (fontSize !== undefined && Number.isFinite(fontSize) && fontSize > 0) {
    document.documentElement.style.setProperty(
      "--body-font-size",
      `${fontSize}px`,
    );
  }
  if (contentWidth !== undefined && Number.isFinite(contentWidth) && contentWidth > 0) {
    document.documentElement.style.setProperty(
      "--content-width",
      `${contentWidth}px`,
    );
  }
}

function setFullWidthLayout(enabled: boolean): void {
  if (enabled) {
    document.documentElement.dataset.layout = "full";
  } else {
    delete document.documentElement.dataset.layout;
  }
}

function setSpellCheck(enabled: boolean): void {
  sourceView.dispatch({
    effects: spellCheckCompartment.reconfigure(spellCheckExtension(enabled)),
  });
  wysiwymElement
    .querySelector(".ProseMirror")
    ?.setAttribute("spellcheck", String(enabled));
}

// Match count for the native find bar over the currently visible mode's
// content: rendered text in preview/WYSIWYM, the CodeMirror doc in source.
function mossmarkCountMatches(query: string, caseSensitive: boolean): number {
  if (query === "") return 0;
  if (currentMode === "source") {
    return countOccurrences(sourceView.state.doc.toString(), query, caseSensitive);
  }
  const root = currentMode === "wysiwym" ? wysiwymElement : previewElement;
  return countOccurrences(root.textContent ?? "", query, caseSensitive);
}

async function prepareForExport(pageHeightRatio?: number): Promise<
  EditorDocumentSnapshot & {
    exportGraphics: ExportGraphic[];
    expectedGraphicCount: number;
  }
> {
  flushWysiwymChange();
  exportViewState = {
    scrollTop: captureScrollPosition().top,
    readingScrollTop,
  };
  document.documentElement.classList.add("is-exporting");
  setVisibleMode("preview");
  try {
    await document.fonts.ready;
    await refreshPreview();
    const expectedGraphicCount = previewElement.querySelectorAll(
      "svg[data-markdown-mermaid-index]",
    ).length;
    const pageHeight = pageHeightRatio
      ? document.documentElement.clientWidth * pageHeightRatio
      : undefined;
    const exportGraphics = await prepareMermaidForExport(previewElement, pageHeight);
    const images = Array.from(document.images);
    await Promise.all(
      images.map(async (element) => {
        if (element.complete) return;
        try {
          await element.decode();
        } catch {
          // The native export layer will preserve a visible broken-image marker.
        }
      }),
    );
    // The final paint positions the rasterized diagrams; an occluded window
    // throttles requestAnimationFrame, so fail the export instead of hanging
    // forever or measuring a stale layout.
    if (!(await nextPaintedLayout())) {
      throw new Error(t("export.layout-timeout"));
    }
    return { ...snapshot(), exportGraphics, expectedGraphicCount };
  } catch (error) {
    // Restore the interactive preview so a failed preparation never strands
    // the editor in its rasterized export layout; the export can be retried.
    document.documentElement.classList.remove("is-exporting");
    exportViewState = undefined;
    await refreshPreview();
    postToNative("mode", { mode: currentMode });
    throw error;
  }
}

async function finishExport(mode: EditorMode): Promise<EditorDocumentSnapshot> {
  document.documentElement.classList.remove("is-exporting");
  const state = exportViewState;
  exportViewState = undefined;

  if (!state) return setMode(mode);

  // A load during the export is authoritative; do not restore the pre-export
  // mode or scroll position over it.
  const loadAtStart = loadSequence;

  // prepareMermaidForExport swapped diagrams for raster images and injected
  // spacer margins, so the reading view must be re-rendered from markdown
  // before it becomes visible again.
  if (mode === "preview") {
    await refreshPreview();
  }
  if (!isCurrentGeneration(loadAtStart, loadSequence)) return snapshot();
  setVisibleMode(mode);
  await nextLayout();
  if (!isCurrentGeneration(loadAtStart, loadSequence)) return snapshot();
  readingScrollTop = state.readingScrollTop;
  window.scrollTo(0, Math.min(maximumScrollTop(), Math.max(0, state.scrollTop)));
  postToNative("mode", { mode: currentMode });
  return snapshot();
}

function getPaginationBreaks(pageHeight: number): number[] {
  const intervals: PaginationInterval[] = [];
  const documentOffset = window.scrollY;
  const walker = document.createTreeWalker(
    previewElement,
    NodeFilter.SHOW_TEXT,
  );
  let node = walker.nextNode();
  while (node) {
    if (node.textContent?.trim()) {
      const range = document.createRange();
      range.selectNodeContents(node);
      for (const rect of range.getClientRects()) {
        if (rect.width <= 0 || rect.height <= 0) continue;
        intervals.push({
          top: rect.top + documentOffset,
          bottom: rect.bottom + documentOffset,
        });
      }
      range.detach();
    }
    node = walker.nextNode();
  }

  previewElement
    .querySelectorAll<HTMLElement>("pre, table, blockquote, figure, img, svg")
    .forEach((element) => {
      const rect = element.getBoundingClientRect();
      if (rect.width <= 0 || rect.height <= 0) return;
      intervals.push({
        top: rect.top + documentOffset,
        bottom: rect.bottom + documentOffset,
      });
    });

  const contentHeight = Math.max(
    document.documentElement.scrollHeight,
    document.body.scrollHeight,
  );
  return calculatePageBreaks(contentHeight, pageHeight, intervals);
}

window.MarkdownEditor = {
  load,
  setMode,
  getSnapshot: () => {
    flushWysiwymChange();
    return snapshot();
  },
  getExportHTML: (title = "Markdown") => {
    flushWysiwymChange();
    return renderStandaloneDocument(currentMarkdown, title);
  },
  getSafetyReport: () => {
    flushWysiwymChange();
    return analyzeMarkdownSafety(currentMarkdown);
  },
  prepareForExport,
  finishExport,
  getPaginationBreaks,
  applyFormatting,
  editTable,
  replaceAllText,
  scrollToHeading,
  setVisualPreference,
  setTypographyPreset,
  setReadingMetrics,
  setFullWidthLayout,
  setSpellCheck,
  setEditable,
  restoreScrollProgress,
  mossmarkCountMatches,
  mossmarkResolveImageImport,
  focus: focusEditor,
};

// Mirror the bridge entry points as bare globals so the native side can call
// them either as window.<fn>(...) or MarkdownEditor.<fn>(...).
window.mossmarkResolveImageImport = mossmarkResolveImageImport;
window.mossmarkCountMatches = mossmarkCountMatches;
window.setReadingMetrics = setReadingMetrics;
window.setFullWidthLayout = setFullWidthLayout;
window.setSpellCheck = setSpellCheck;
window.restoreScrollProgress = restoreScrollProgress;

previewElement.addEventListener("pointerdown", (event) => {
  if (currentMode !== "preview" || event.button !== 0) return;
  readingPointerStart = { x: event.clientX, y: event.clientY };
});

previewElement.addEventListener("pointercancel", () => {
  readingPointerStart = undefined;
});

previewElement.addEventListener("pointerup", (event) => {
  const start = readingPointerStart;
  readingPointerStart = undefined;
  if (!start || currentMode !== "preview") return;
  if (document.documentElement.classList.contains("is-exporting")) return;

  // Taps on interactive content (links, task checkboxes, diagrams,
  // footnotes) belong to that content, not the immersive-mode toggle.
  if (
    event.target instanceof Element &&
    event.target.closest("a, input, .mermaid, .footnotes")
  ) {
    return;
  }

  const distance = Math.hypot(event.clientX - start.x, event.clientY - start.y);
  const selection = window.getSelection();
  if (distance > 8 || (selection && !selection.isCollapsed)) return;
  postToNative("reading-tap", {});
});

// Internal anchors (footnotes, TOC entries) scroll inside the reading view
// instead of triggering a native navigation.
previewElement.addEventListener("click", (event) => {
  const anchor =
    event.target instanceof Element
      ? event.target.closest<HTMLAnchorElement>('a[href^="#"]')
      : null;
  if (!anchor) return;
  const href = anchor.getAttribute("href") ?? "";
  let id = "";
  try {
    id = decodeURIComponent(href.slice(1));
  } catch {
    return;
  }
  if (!id) return;
  const target = document.getElementById(id);
  if (!target || !previewElement.contains(target)) return;
  event.preventDefault();
  target.scrollIntoView({
    behavior: prefersReducedMotion() ? "auto" : "smooth",
    block: "start",
  });
});

// Esc in reading mode is the native side's cue to leave immersive reading.
document.addEventListener("keydown", (event) => {
  if (event.key === "Escape" && currentMode === "preview") {
    postToNative("reading-escape", {});
  }
});

// Re-render so Mermaid diagrams pick up the neutral/dark theme switch.
window
  .matchMedia("(prefers-color-scheme: dark)")
  .addEventListener("change", () => {
    void refreshPreview();
  });

document.addEventListener("selectionchange", updateFocusedBlock);
document.addEventListener("visibilitychange", () => {
  if (document.visibilityState === "hidden") flushWysiwymChange();
});
window.addEventListener("scroll", scheduleHeadingUpdate, { passive: true });
window.addEventListener("scroll", scheduleScrollProgressReport, { passive: true });
window.addEventListener("pagehide", () => {
  flushWysiwymChange();
});

void crepe
  .create()
  .then(async () => {
    await load({ markdown: "", revision: 0, mode: "preview" });
    postToNative("ready", snapshot());
  })
  .catch((error: unknown) => {
    postToNative("error", {
      message: error instanceof Error ? error.message : String(error),
      operation: "initialize-editor",
    });
  });

window.addEventListener("beforeunload", () => {
  flushWysiwymChange();
  sourceView.destroy();
  void crepe.destroy();
});
