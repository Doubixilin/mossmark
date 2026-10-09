import { t } from "./i18n";
import { renderMarkdown } from "./renderer";

type MermaidAPI = (typeof import("mermaid"))["default"];
type MermaidTheme = "neutral" | "dark";

let mermaidModule: MermaidAPI | undefined;
let mermaidTheme: MermaidTheme | undefined;
// Serialized so a new render never overlaps with an in-flight mermaid.run.
let mermaidQueue: Promise<unknown> = Promise.resolve();
// Rendered SVG markup keyed by theme + diagram source, so re-rendering the
// preview (which rebuilds the DOM) does not re-run mermaid for unchanged
// diagrams, while a dark/light switch still re-renders with the new theme.
const mermaidCache = new Map<string, string>();

function currentMermaidTheme(): MermaidTheme {
  return window.matchMedia("(prefers-color-scheme: dark)").matches
    ? "dark"
    : "neutral";
}

// Mermaid is large, so load it lazily the first time a diagram appears.
async function loadMermaid(): Promise<MermaidAPI> {
  const theme = currentMermaidTheme();
  if (!mermaidModule) {
    mermaidModule = (await import("mermaid")).default;
    mermaidTheme = theme;
  } else if (mermaidTheme !== theme) {
    mermaidTheme = theme;
  }
  mermaidModule.initialize({
    startOnLoad: false,
    securityLevel: "strict",
    theme: mermaidTheme,
    suppressErrorRendering: false,
  });
  return mermaidModule;
}

export interface ExportGraphic {
  kind: "mermaid";
  key: string;
  dataURL: string;
  x: number;
  y: number;
  width: number;
  height: number;
}

function missingImageFallback(image: HTMLImageElement): HTMLElement {
  const fallback = document.createElement("span");
  fallback.className = "missing-image";
  fallback.setAttribute("role", "img");
  const label = image.alt.trim() || image.getAttribute("src") || t("image.unnamed");
  fallback.setAttribute("aria-label", label);
  fallback.textContent = t("image.unavailable", { label });
  return fallback;
}

function installImageFallbacks(element: HTMLElement): void {
  element.querySelectorAll<HTMLImageElement>("img").forEach((image) => {
    const replace = () => {
      if (!image.isConnected) return;
      image.replaceWith(missingImageFallback(image));
    };
    if (image.complete && image.naturalWidth === 0) {
      replace();
    } else {
      image.addEventListener("error", replace, { once: true });
    }
  });
}

function escapeText(source: string): string {
  return source
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;");
}

/**
 * Waits for a double animation frame (one full layout + paint cycle) and
 * resolves true once it fired. Occluded or background WKWebViews throttle
 * requestAnimationFrame indefinitely, so a timer resolves false instead;
 * export callers treat that as a recoverable failure rather than measuring
 * a stale layout or hanging forever. The frame scheduler is injectable so
 * the timeout path is testable without a DOM.
 */
export function nextPaintedLayout(
  timeoutMs = 1000,
  scheduleFrames: (callback: () => void) => void = (callback) => {
    requestAnimationFrame(() => requestAnimationFrame(callback));
  },
): Promise<boolean> {
  return new Promise((resolve) => {
    let settled = false;
    const finish = (painted: boolean): void => {
      if (settled) return;
      settled = true;
      resolve(painted);
    };
    scheduleFrames(() => finish(true));
    setTimeout(() => finish(false), timeoutMs);
  });
}

export interface TocHeading {
  level: number;
  id: string;
  text: string;
}

// Nested <ul> markup for the heading list; headings link to the same
// md-heading-N ids scrollToHeading/outline use in document order.
export function buildTocMarkup(headings: TocHeading[]): string {
  let html = "";
  const levels: number[] = [];
  for (const heading of headings) {
    const level = Math.min(6, Math.max(1, heading.level));
    while (levels.length > 0 && level < levels[levels.length - 1]!) {
      html += "</li></ul>";
      levels.pop();
    }
    if (levels.length === 0 || level > levels[levels.length - 1]!) {
      html += "<ul>";
      levels.push(level);
    } else {
      html += "</li>";
    }
    html += `<li><a href="#${heading.id}">${escapeText(heading.text)}</a>`;
  }
  while (levels.length > 0) {
    html += "</li></ul>";
    levels.pop();
  }
  return html;
}

const TOC_MARKER = /^\[\[?toc\]?\]$/i;

// Replaces paragraphs containing only a [TOC]/[[toc]] marker with a nested
// list generated from the rendered h1-h6 elements.
function installTableOfContents(element: HTMLElement): void {
  const targets = Array.from(element.querySelectorAll("p")).filter(
    (paragraph) =>
      paragraph.children.length === 0 &&
      TOC_MARKER.test(paragraph.textContent?.trim() ?? ""),
  );
  if (targets.length === 0) return;

  const headings = Array.from(
    element.querySelectorAll<HTMLElement>("h1, h2, h3, h4, h5, h6"),
  );
  if (headings.length === 0) return;
  headings.forEach((heading, index) => {
    if (!heading.id) heading.id = `md-heading-${index}`;
  });
  const markup = buildTocMarkup(
    headings.map((heading) => ({
      level: Number(heading.tagName.slice(1)),
      id: heading.id,
      text: heading.textContent?.trim() ?? "",
    })),
  );
  for (const target of targets) {
    const nav = document.createElement("nav");
    nav.className = "md-toc";
    nav.setAttribute("aria-label", t("toc.label"));
    nav.innerHTML = markup;
    target.replaceWith(nav);
  }
}

export async function renderInto(element: HTMLElement, source: string): Promise<void> {
  element.innerHTML = renderMarkdown(source);
  installImageFallbacks(element);
  installTableOfContents(element);
  const diagrams = Array.from(element.querySelectorAll<HTMLElement>(".mermaid"));
  if (diagrams.length === 0) return;

  const theme = currentMermaidTheme();
  const pending: HTMLElement[] = [];
  diagrams.forEach((diagram) => {
    const diagramSource = diagram.textContent ?? "";
    diagram.dataset.mermaidSource = diagramSource;
    const cached = mermaidCache.get(`${theme}\n${diagramSource}`);
    if (cached !== undefined) {
      diagram.innerHTML = cached;
    } else {
      pending.push(diagram);
    }
  });

  if (pending.length > 0) {
    const mermaid = await loadMermaid();
    const run = mermaidQueue.then(() =>
      mermaid.run({ nodes: pending, suppressErrors: true }),
    );
    mermaidQueue = run.catch(() => undefined);
    await run;
    pending.forEach((diagram) => {
      const diagramSource = diagram.dataset.mermaidSource ?? "";
      // Cache the pristine mermaid output; the sizing pass below re-applies
      // its attributes on every render, cached or not.
      const svg = diagram.querySelector<SVGSVGElement>("svg");
      if (svg && diagram.isConnected) {
        mermaidCache.set(`${theme}\n${diagramSource}`, svg.outerHTML);
      }
    });
  }

  diagrams.forEach((diagram, index) => {
    const svg = diagram.querySelector<SVGSVGElement>("svg");
    if (!svg) return;
    const viewBox = svg.viewBox.baseVal;
    if (viewBox.width > 0 && viewBox.height > 0) {
      // Mermaid uses a responsive width without an intrinsic height. WKWebView
      // collapses that SVG to zero height, so preserve its viewBox dimensions.
      svg.setAttribute("width", String(Math.ceil(viewBox.width)));
      svg.setAttribute("height", String(Math.ceil(viewBox.height)));
    }
    svg.setAttribute("data-markdown-mermaid-index", String(index));
  });
}

function replaceForeignObjectLabels(svg: SVGSVGElement): void {
  svg.querySelectorAll<SVGForeignObjectElement>("foreignObject").forEach((foreignObject) => {
    const label = (foreignObject.textContent ?? "").replace(/\s+/g, " ").trim();
    const x = Number.parseFloat(foreignObject.getAttribute("x") ?? "0");
    const y = Number.parseFloat(foreignObject.getAttribute("y") ?? "0");
    const width = Number.parseFloat(foreignObject.getAttribute("width") ?? "0");
    const height = Number.parseFloat(foreignObject.getAttribute("height") ?? "0");
    const text = document.createElementNS("http://www.w3.org/2000/svg", "text");
    text.setAttribute("x", String(x + width / 2));
    text.setAttribute("y", String(y + height / 2));
    text.setAttribute("text-anchor", "middle");
    text.setAttribute("dominant-baseline", "middle");
    text.setAttribute("font-family", "-apple-system, BlinkMacSystemFont, sans-serif");
    text.setAttribute("font-size", "16");
    text.setAttribute("fill", "#222");
    text.textContent = label;
    foreignObject.replaceWith(text);
  });
}

async function imageFromURL(url: string): Promise<HTMLImageElement> {
  const image = new Image();
  image.src = url;
  await image.decode();
  return image;
}

export async function prepareMermaidForExport(
  element: HTMLElement,
  pageHeight?: number,
): Promise<ExportGraphic[]> {
  const diagrams = Array.from(
    element.querySelectorAll<HTMLElement>("[data-mermaid-source]"),
  );
  const graphics: ExportGraphic[] = [];
  const rendered: Array<{
    graphic: ExportGraphic;
    wrapper: HTMLDivElement;
    image: HTMLImageElement;
  }> = [];
  for (const [diagramIndex, diagram] of diagrams.entries()) {
      const source = diagram.dataset.mermaidSource ?? t("mermaid.diagram");
      const svg = diagram.querySelector<SVGSVGElement>("svg");
      try {
        if (!svg) throw new Error("Mermaid did not produce an SVG element.");
        const svgBounds = svg.getBoundingClientRect();
        const diagramBounds = diagram.getBoundingClientRect();
        const width = Math.max(1, Math.ceil(svgBounds.width));
        const height = Math.max(1, Math.ceil(svgBounds.height));
        const clone = svg.cloneNode(true) as SVGSVGElement;
        clone.setAttribute("xmlns", "http://www.w3.org/2000/svg");
        clone.setAttribute("width", String(width));
        clone.setAttribute("height", String(height));
        replaceForeignObjectLabels(clone);
        const markup = new XMLSerializer().serializeToString(clone);
        const blobURL = URL.createObjectURL(
          new Blob([markup], { type: "image/svg+xml;charset=utf-8" }),
        );
        try {
          const image = await imageFromURL(blobURL);
          const scale = 2;
          const canvas = document.createElement("canvas");
          canvas.width = width * scale;
          canvas.height = height * scale;
          const context = canvas.getContext("2d");
          if (!context) throw new Error("Canvas 2D is unavailable.");
          context.scale(scale, scale);
          context.drawImage(image, 0, 0, width, height);
          const dataURL = canvas.toDataURL("image/png");
          const exportImage = document.createElement("img");
          exportImage.className = "mermaid-export-image";
          exportImage.src = dataURL;
          exportImage.alt = t("mermaid.diagram");
          exportImage.width = width;
          exportImage.height = height;
          await exportImage.decode();
          const graphic: ExportGraphic = {
            kind: "mermaid",
            key: `markdown-generated://diagram/${diagramIndex}`,
            dataURL,
            x: svgBounds.left + window.scrollX,
            y: svgBounds.top + window.scrollY,
            width,
            height,
          };
          graphics.push(graphic);
          const replacement = document.createElement("div");
          replacement.className = "mermaid-export-image-wrapper";
          replacement.style.minHeight = `${Math.max(height, diagramBounds.height)}px`;
          replacement.setAttribute("role", "img");
          replacement.setAttribute("aria-label", t("mermaid.diagram"));
          replacement.append(exportImage);
          diagram.replaceWith(replacement);
          rendered.push({ graphic, wrapper: replacement, image: exportImage });
        } finally {
          URL.revokeObjectURL(blobURL);
        }
      } catch (error) {
        const fallback = document.createElement("pre");
        fallback.className = "diagram-fallback";
        const reason = error instanceof Error ? error.message : String(error);
        fallback.textContent = `${t("mermaid.raster-failed", { reason })}\n${source}`;
        diagram.replaceWith(fallback);
      }
  }
  // The swapped-in raster images must be laid out before their bounds are
  // measured; a throttled rAF turns this into a recoverable export error.
  if (!(await nextPaintedLayout())) {
    throw new Error(t("export.layout-timeout"));
  }
  if (pageHeight && Number.isFinite(pageHeight) && pageHeight > 0) {
    for (const item of rendered) {
      const bounds = item.image.getBoundingClientRect();
      const documentY = bounds.top + window.scrollY;
      const pageOffset = ((documentY % pageHeight) + pageHeight) % pageHeight;
      if (pageOffset + bounds.height > pageHeight) {
        item.wrapper.style.marginTop = `${pageHeight - pageOffset}px`;
      }
    }
    if (!(await nextPaintedLayout())) {
      throw new Error(t("export.layout-timeout"));
    }
  }
  for (const item of rendered) {
    const bounds = item.image.getBoundingClientRect();
    item.graphic.x = bounds.left + window.scrollX;
    item.graphic.y = bounds.top + window.scrollY;
    item.graphic.width = bounds.width;
    item.graphic.height = bounds.height;
  }
  return graphics;
}
