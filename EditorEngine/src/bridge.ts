export const EDITOR_BRIDGE_PROTOCOL_VERSION = 1 as const;

export type EditorMode = "wysiwym" | "source" | "preview";

export interface EditorDocumentSnapshot {
  protocolVersion: typeof EDITOR_BRIDGE_PROTOCOL_VERSION;
  revision: number;
  markdown: string;
  mode: EditorMode;
}

export interface BridgeMessage {
  protocolVersion: typeof EDITOR_BRIDGE_PROTOCOL_VERSION;
  type:
    | "ready"
    | "change"
    | "mode"
    | "reading-tap"
    | "reading-escape"
    | "import-image"
    | "scroll-progress"
    | "outline"
    | "warning"
    | "error";
  payload: unknown;
}

interface NativeMessageHandler {
  postMessage(message: BridgeMessage): void;
}

declare global {
  interface Window {
    webkit?: {
      messageHandlers?: {
        markdownBridge?: NativeMessageHandler;
      };
    };
  }
}

export function postToNative(
  type: BridgeMessage["type"],
  payload: unknown,
): void {
  window.webkit?.messageHandlers?.markdownBridge?.postMessage({
    protocolVersion: EDITOR_BRIDGE_PROTOCOL_VERSION,
    type,
    payload,
  });
}
