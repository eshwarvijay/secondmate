import MarkdownIt from "markdown-it";

/**
 * markdown-it configuration for rendering the repo's own docs at build time.
 * - Headings get stable slug ids (and are collected for the docs-page TOC).
 * - ```mermaid fences become <div class="mermaid"> placeholders that a client
 *   component hydrates into SVGs after load.
 * - Fences get a small language label; tables get a horizontal-scroll wrapper.
 * - Relative links into the repo (docs/…) are rewritten to site routes and
 *   internal links are prefixed with the export base path.
 */

export interface TocEntry {
  depth: number;
  text: string;
  slug: string;
}

const BASE_PATH = process.env.NEXT_PUBLIC_BASE_PATH ?? "";

function escapeHtml(text: string): string {
  return text
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

export function slugify(text: string): string {
  return text
    .toLowerCase()
    .replace(/<[^>]+>/g, "")
    .replace(/[`*_]/g, "")
    .replace(/[^\p{L}\p{N}]+/gu, "-")
    .replace(/^-+|-+$/g, "");
}

function rewriteHref(href: string): { href: string; external: boolean } {
  if (/^https?:\/\//i.test(href)) return { href, external: true };
  if (href.startsWith("#") || href.startsWith("mailto:")) return { href, external: false };
  // Repo-relative doc links → site routes.
  if (/^docs\/ARCHITECTURE\.md/.test(href)) {
    return { href: `${BASE_PATH}/architecture/`, external: false };
  }
  if (/^README\.md/.test(href)) return { href: `${BASE_PATH}/`, external: false };
  // Anything else repo-relative points back at GitHub.
  return {
    href: `https://github.com/eshwarvijay/secondmate/blob/main/${href}`,
    external: true,
  };
}

export function createMd(collectToc = false): { md: MarkdownIt; toc: TocEntry[] } {
  const toc: TocEntry[] = [];
  const md = new MarkdownIt({
    html: false,
    linkify: true,
    typographer: false,
  });

  md.renderer.rules.heading_open = (tokens, idx, _opts, env: { toc?: TocEntry[] }) => {
    const inline = tokens[idx + 1];
    const text = (inline?.content ?? "").replace(/[`*_]/g, "");
    const slug = slugify(inline?.content ?? "");
    const depth = Number(tokens[idx].tag.slice(1));
    if (collectToc && (depth === 2 || depth === 3)) {
      toc.push({ depth, text, slug });
    }
    void env;
    return `<h${depth} id="${escapeHtml(slug)}">`;
  };

  md.renderer.rules.fence = (tokens, idx) => {
    const token = tokens[idx];
    const lang = token.info.trim().split(/\s+/)[0] ?? "";
    if (lang === "mermaid") {
      const encoded = Buffer.from(token.content, "utf8").toString("base64");
      return (
        `<div class="mermaid" data-source="${encoded}">` +
        `<pre class="mermaid-source"><code>${escapeHtml(token.content)}</code></pre></div>`
      );
    }
    return (
      `<div class="codeblock"${lang ? ` data-lang="${escapeHtml(lang)}"` : ""}>` +
      `<pre><code>${escapeHtml(token.content)}</code></pre></div>`
    );
  };

  md.renderer.rules.table_open = () => `<div class="table-wrap"><table>`;
  md.renderer.rules.table_close = () => `</table></div>`;

  const defaultLinkOpen =
    md.renderer.rules.link_open ??
    ((tokens, idx, options, _env, self) => self.renderToken(tokens, idx, options));
  md.renderer.rules.link_open = (tokens, idx, options, env, self) => {
    const hrefIdx = tokens[idx].attrIndex("href");
    if (hrefIdx >= 0) {
      const original = tokens[idx].attrs![hrefIdx][1];
      const { href, external } = rewriteHref(original);
      tokens[idx].attrs![hrefIdx][1] = href;
      if (external) {
        tokens[idx].attrSet("target", "_blank");
        tokens[idx].attrSet("rel", "noopener noreferrer");
      }
    }
    return defaultLinkOpen(tokens, idx, options, env, self);
  };

  return { md, toc };
}

export function renderMarkdown(source: string): { html: string; toc: TocEntry[] } {
  const { md, toc } = createMd(true);
  return { html: md.render(source), toc };
}

export function renderInline(source: string): string {
  const { md } = createMd(false);
  return md.renderInline(source);
}
