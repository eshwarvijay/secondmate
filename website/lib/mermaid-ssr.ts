/**
 * Build-time mermaid renderer.
 *
 * The site is a static export, so diagrams are rendered to inline SVG during
 * `next build` — no multi-megabyte mermaid bundle is shipped to the browser,
 * and the exported HTML shows a real diagram even with JS disabled.
 *
 * Mermaid expects browser APIs, so this wires up a jsdom window before the
 * first render and polyfills the SVG text measurement jsdom lacks (getBBox).
 * Measurements are approximate (fixed per-character width), which is fine for
 * flowchart boxes but means node padding may differ slightly from a browser.
 *
 * If a diagram ever fails to render at build time, the caller falls back to a
 * readable source block instead of failing the build.
 */

const FONT_SIZE = 14;
const CHAR_WIDTH = FONT_SIZE * 0.66; // avg sans-serif advance at 14px
const LINE_HEIGHT = FONT_SIZE * 1.3;
/**
 * The viewBox comes from the same approximate measurement as the layout, so
 * any element mermaid positions against a *different* anchor (e.g. an edge
 * label centered by its estimated width) can poke past it. Inflating the
 * viewBox by a fixed margin keeps such elements visible; the diagram just
 * renders imperceptibly smaller within its container.
 */
const VIEWBOX_MARGIN = 28;

interface Box {
  x: number;
  y: number;
  width: number;
  height: number;
}

function installSvgMeasurementPolyfill(svgElementProto: object): void {
  const num = (v: string | null | undefined): number => (v ? parseFloat(v) || 0 : 0);

  const union = (a: Box, b: Box): Box => {
    const x = Math.min(a.x, b.x);
    const y = Math.min(a.y, b.y);
    return {
      x,
      y,
      width: Math.max(a.x + a.width, b.x + b.width) - x,
      height: Math.max(a.y + a.height, b.y + b.height) - y,
    };
  };

  function measure(el: Element): Box {
    const tag = el.tagName;
    if (tag === "text" || tag === "tspan") {
      // Mermaid splits multi-line labels into one <tspan> row per line.
      const rows = el.querySelectorAll(":scope > tspan");
      const lineLengths =
        rows.length > 0
          ? Array.from(rows).map((r) => (r.textContent ?? "").length)
          : [Math.max(1, (el.textContent ?? "").length)];
      const width = Math.max(...lineLengths, 1) * CHAR_WIDTH + 16; // + label padding
      const height = Math.max(1, lineLengths.length) * LINE_HEIGHT;
      // y attribute is the baseline; approximate the box above it.
      return { x: num(el.getAttribute("x")), y: num(el.getAttribute("y")) - height * 0.8, width, height };
    }
    if (tag === "rect") {
      return {
        x: num(el.getAttribute("x")),
        y: num(el.getAttribute("y")),
        width: num(el.getAttribute("width")),
        height: num(el.getAttribute("height")),
      };
    }
    if (tag === "path") {
      // Edge paths from d3 curve generators use absolute coordinates.
      const nums = (el.getAttribute("d") ?? "").match(/-?\d*\.?\d+(?:e[-+]?\d+)?/gi)?.map(Number) ?? [];
      let minX = Infinity,
        minY = Infinity,
        maxX = -Infinity,
        maxY = -Infinity;
      for (let i = 0; i + 1 < nums.length; i += 2) {
        minX = Math.min(minX, nums[i]);
        maxX = Math.max(maxX, nums[i]);
        minY = Math.min(minY, nums[i + 1]);
        maxY = Math.max(maxY, nums[i + 1]);
      }
      return isFinite(minX)
        ? { x: minX, y: minY, width: maxX - minX, height: maxY - minY }
        : { x: 0, y: 0, width: 0, height: 0 };
    }
    // Container: union of children, then apply own translate().
    let box: Box | null = null;
    for (const child of Array.from(el.children)) {
      const b = measure(child);
      box = box ? union(box, b) : b;
    }
    box ??= { x: 0, y: 0, width: 0, height: 0 };
    const t = /translate\(\s*(-?[\d.]+)(?:[ ,]\s*(-?[\d.]+))?/.exec(el.getAttribute("transform") ?? "");
    if (t) box = { ...box, x: box.x + num(t[1]), y: box.y + num(t[2]) };
    return box;
  }

  const proto = svgElementProto as { getBBox?: unknown; getComputedTextLength?: unknown };
  proto.getBBox = function (this: Element) {
    const b = measure(this);
    return { ...b, top: b.y, left: b.x, right: b.x + b.width, bottom: b.y + b.height };
  };
  proto.getComputedTextLength = function (this: Element) {
    return (this.textContent ?? "").length * CHAR_WIDTH;
  };
}

type RenderFn = (id: string, source: string) => Promise<string>;
let rendererPromise: Promise<RenderFn> | null = null;

/** Expands the rendered viewBox (and matching max-width) by VIEWBOX_MARGIN. */
function inflateViewBox(svg: string): string {
  const match = /viewBox="(-?[\d.]+) (-?[\d.]+) ([\d.]+) ([\d.]+)"/.exec(svg);
  if (!match) return svg;
  const [, x, y, w, h] = match.map(Number);
  const nx = x - VIEWBOX_MARGIN;
  const ny = y - VIEWBOX_MARGIN;
  const nw = w + VIEWBOX_MARGIN * 2;
  const nh = h + VIEWBOX_MARGIN * 2;
  return svg
    .replace(match[0], `viewBox="${nx} ${ny} ${nw} ${nh}"`)
    .replace(`max-width: ${w}px`, `max-width: ${nw}px`);
}

async function createRenderer(): Promise<RenderFn> {
  const { JSDOM } = await import("jsdom");
  const dom = new JSDOM("<!DOCTYPE html><html><body></body></html>", {
    pretendToBeVisual: true,
  });

  // Expose jsdom window APIs mermaid (and its bundled DOMPurify) expect to
  // find as globals, without clobbering Node's own globals.
  const g = globalThis as unknown as Record<string, unknown>;
  const win = dom.window as unknown as Record<string, unknown>;
  for (const key of Object.getOwnPropertyNames(dom.window)) {
    if (key in g) continue;
    try {
      g[key] = win[key];
    } catch {
      /* read-only property, skip */
    }
  }
  installSvgMeasurementPolyfill(dom.window.SVGElement.prototype);

  const mermaid = (await import("mermaid")).default;
  mermaid.initialize({
    startOnLoad: false,
    securityLevel: "loose", // content is this repo's own trusted docs
    theme: "dark",
    themeVariables: {
      background: "#0e1013",
      primaryColor: "#121418",
      primaryTextColor: "#ebebed",
      primaryBorderColor: "rgba(255,255,255,0.25)",
      secondaryColor: "#0e1013",
      tertiaryColor: "#0e1013",
      lineColor: "#9ba1a8",
      textColor: "#ebebed",
      fontFamily:
        '-apple-system, BlinkMacSystemFont, "SF Pro Text", "Inter", "Segoe UI", Roboto, sans-serif',
      fontSize: `${FONT_SIZE}px`,
    },
    // htmlLabels must stay off for SSR: foreignObject labels are measured via
    // DOM layout (offsetWidth), which jsdom reports as 0.
    flowchart: { htmlLabels: false, useMaxWidth: true },
  });

  return async (id, source) => inflateViewBox((await mermaid.render(id, source)).svg);
}

/** Renders mermaid source to an SVG string, or null if rendering fails. */
export async function renderMermaidToSvg(id: string, source: string): Promise<string | null> {
  try {
    rendererPromise ??= createRenderer();
    return await (await rendererPromise)(id, source);
  } catch (err) {
    console.warn(
      `website: mermaid render failed for "${id}", keeping readable source block instead:`,
      err instanceof Error ? err.message : err,
    );
    return null;
  }
}
