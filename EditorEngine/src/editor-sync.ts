import type { EditorMode } from "./bridge";

export interface WysiwymUpdateContext {
  mode: EditorMode;
  editable: boolean;
  currentRevision: number;
  synchronizedRevision: number | undefined;
  currentMarkdown: string;
  incomingMarkdown: string;
}

/**
 * A debounced rich-editor callback is authoritative only while it still
 * belongs to the visible, editable WYSIWYM revision it was synchronized from.
 */
export function shouldAcceptWysiwymUpdate(
  context: WysiwymUpdateContext,
): boolean {
  return context.mode === "wysiwym" &&
    context.editable &&
    context.synchronizedRevision !== undefined &&
    context.synchronizedRevision === context.currentRevision &&
    context.incomingMarkdown !== context.currentMarkdown;
}

export interface WysiwymTransactionContext {
  docChanged: boolean;
  addToHistory: unknown;
  internalEditorUpdate: boolean;
}

/**
 * User document transactions must be serialized before the next OS event so a
 * window-close command cannot outrun Milkdown's debounced listener. Internal
 * replacement and non-history normalization transactions are synchronized by
 * their owning operation instead.
 */
export function shouldSynchronizeWysiwymTransaction(
  context: WysiwymTransactionContext,
): boolean {
  return context.docChanged &&
    context.addToHistory !== false &&
    !context.internalEditorUpdate;
}

/**
 * Long-running bridge entry points (load, mode switches, export restore)
 * record a monotonically increasing generation when they start. After every
 * await the recorded value must still be the current one; otherwise a newer
 * call has superseded this one and the stale call must stop without posting
 * to native, switching modes, or touching cached state.
 */
export function isCurrentGeneration(started: number, current: number): boolean {
  return started === current;
}

export interface ImageImportContext {
  revision: number;
  mode: EditorMode;
  editorGeneration: number;
  editabilityGeneration: number;
}

export interface CurrentImageImportContext extends ImageImportContext {
  editable: boolean;
}

/**
 * Image uploads finish asynchronously. Never apply their result to a newer
 * revision, a different surface/session, or a document that became readonly.
 */
export function isCurrentImageImportContext(
  started: ImageImportContext,
  current: CurrentImageImportContext,
): boolean {
  return started.mode === "wysiwym" &&
    current.mode === "wysiwym" &&
    current.editable &&
    started.revision === current.revision &&
    started.editorGeneration === current.editorGeneration &&
    started.editabilityGeneration === current.editabilityGeneration;
}
