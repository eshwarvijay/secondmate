"use client";

import { useEffect } from "react";

/**
 * Finds every <div class="mermaid" data-source="…"> emitted by the build-time
 * markdown renderer and replaces the readable source fallback with a rendered
 * SVG. Mermaid is imported lazily so the landing page never pays for it.
 */
export function MermaidHydrator() {
  useEffect(() => {
    let cancelled = false;

    const decode = (b64: string): string =>
      new TextDecoder().decode(Uint8Array.from(atob(b64), (c) => c.charCodeAt(0)));

    (async () => {
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
          fontSize: "14px",
        },
        flowchart: { htmlLabels: true, useMaxWidth: true },
      });

      const nodes = Array.from(document.querySelectorAll<HTMLElement>(".mermaid[data-source]"));
      for (const [i, el] of nodes.entries()) {
        const source = decode(el.dataset.source ?? "");
        try {
          const { svg } = await mermaid.render(`mermaid-diagram-${i}`, source);
          if (!cancelled) el.innerHTML = svg;
        } catch (err) {
          // Leave the readable mermaid source in place if rendering fails.
          console.error("mermaid render failed", err);
        }
      }
    })();

    return () => {
      cancelled = true;
    };
  }, []);

  return null;
}
