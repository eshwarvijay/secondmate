"use client";

import { useEffect, useState } from "react";
import type { TocEntry } from "@/lib/markdown";

/**
 * Docs-page table of contents with scroll-spy. Purely functional feedback
 * (no animation): the active entry is highlighted as you scroll.
 */
export function DocsToc({ entries }: { entries: TocEntry[] }) {
  const [active, setActive] = useState<string | null>(null);

  useEffect(() => {
    const headings = entries
      .map((e) => document.getElementById(e.slug))
      .filter((el): el is HTMLElement => el !== null);
    if (headings.length === 0) return;

    const observer = new IntersectionObserver(
      (observed) => {
        for (const entry of observed) {
          if (entry.isIntersecting) setActive(entry.target.id);
        }
      },
      { rootMargin: "-20% 0px -70% 0px" },
    );
    headings.forEach((h) => observer.observe(h));
    return () => observer.disconnect();
  }, [entries]);

  return (
    <nav className="docs-toc" aria-label="On this page">
      <p className="toc-title">On this page</p>
      <ul>
        {entries.map((e) => (
          <li key={e.slug}>
            <a
              href={`#${e.slug}`}
              className={e.depth === 3 ? "toc-depth-3" : undefined}
              data-active={active === e.slug}
            >
              {e.text}
            </a>
          </li>
        ))}
      </ul>
    </nav>
  );
}
