import type { Metadata } from "next";
import { DocsToc } from "@/components/DocsToc";
import { MermaidHydrator } from "@/components/MermaidHydrator";
import { getArchitecture } from "@/lib/parse";
import { renderMarkdown } from "@/lib/markdown";

export const metadata: Metadata = {
  title: "Architecture",
  description: "How secondmate turns a single coding agent into a maker/checker crew.",
};

/* The whole page below is docs/ARCHITECTURE.md rendered at build time. */

const arch = getArchitecture();
const { html, toc } = renderMarkdown(arch.markdown);

export default function ArchitecturePage() {
  return (
    <div className="container docs-layout">
      <aside>
        <DocsToc entries={toc} />
      </aside>
      <article className="prose" dangerouslySetInnerHTML={{ __html: html }} />
      <MermaidHydrator />
    </div>
  );
}
