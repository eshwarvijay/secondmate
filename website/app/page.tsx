import Link from "next/link";
import { CopyButton } from "@/components/CopyButton";
import { GlowingEffect } from "@/components/GlowingEffect";
import { Spotlight } from "@/components/Spotlight";
import { getReadme, getArchitecture } from "@/lib/parse";
import { getPluginMeta } from "@/lib/repo";
import { renderMarkdown, renderInline } from "@/lib/markdown";

/* All content below is parsed at build time from the repo's own files:
   README.md, docs/ARCHITECTURE.md, .claude-plugin/plugin.json and bin/. */

const plugin = getPluginMeta();
const readme = getReadme();
const arch = getArchitecture();

const introParagraphs = readme.intro.split(/\n\n+/);
const heroLede = introParagraphs[0];
const howItWorksLede = introParagraphs.slice(1).join("\n\n");

const quickStart = (await renderMarkdown(readme.quickStart)).html;
const requirements = (await renderMarkdown(readme.requirements)).html;
const howItWorksLedeHtml = (await renderMarkdown(howItWorksLede)).html;

/* One glyph per role -- plain geometric pictograms (wheel, eye, fork,
   stacked bars, pencil, magnifying glass), same 16x16/stroke-1.5 language
   as the rest of the icon set. Generic iconography, not any specific
   product's mark. */
function RoleIcon({ role }: { role: string }) {
  const common = {
    viewBox: "0 0 16 16",
    fill: "none",
    stroke: "currentColor",
    strokeWidth: 1.5,
    strokeLinecap: "round" as const,
    strokeLinejoin: "round" as const,
    "aria-hidden": true,
  };
  if (role.includes("Captain")) {
    return (
      <svg {...common}>
        <circle cx="8" cy="8" r="5.5" />
        <circle cx="8" cy="8" r="1.1" fill="currentColor" stroke="none" />
        <path d="M8 2.5v2.3M8 13.2v-2.3M2.5 8h2.3M13.2 8h-2.3" />
      </svg>
    );
  }
  if (role.includes("Top-level")) {
    return (
      <svg {...common}>
        <path d="M1.5 8c1.8-3 4-4.5 6.5-4.5s4.7 1.5 6.5 4.5c-1.8 3-4 4.5-6.5 4.5S3.3 11 1.5 8Z" />
        <circle cx="8" cy="8" r="1.7" />
      </svg>
    );
  }
  if (role.includes("Sub-agent")) {
    return (
      <svg {...common}>
        <path d="M8 2v3.5M8 5.5 4.5 9v3.5M8 5.5 11.5 9v3.5" />
      </svg>
    );
  }
  if (role.includes("Planners")) {
    return (
      <svg {...common}>
        <path d="M3 4.5h10M3 8h7M3 11.5h10" />
      </svg>
    );
  }
  if (role.includes("Maker")) {
    return (
      <svg {...common}>
        <path d="M3 13 3.8 9.8 10.3 3.3c.5-.5 1.3-.5 1.8 0l.6.6c.5.5.5 1.3 0 1.8L6.2 12.2 3 13Z" />
        <path d="M9 5l2 2" />
      </svg>
    );
  }
  return (
    <svg {...common}>
      <circle cx="6.8" cy="6.8" r="4.3" />
      <path d="M10.2 10.2 14 14" />
    </svg>
  );
}

/* Hand-drawn "not equal" mark for the hero -- a plain Unicode "≠" glyph
   renders thin and inconsistently across fonts at this scale next to an
   800-weight headline; a custom shape gives full, deliberate control over
   its stroke weight so it actually matches the surrounding text. */
function NotEqualIcon() {
  return (
    <svg
      className="hero-equation-symbol"
      viewBox="0 0 64 64"
      fill="none"
      stroke="currentColor"
      strokeWidth="9"
      strokeLinecap="round"
      aria-hidden
    >
      <path d="M8 24h48" />
      <path d="M8 40h48" />
      <path d="M44 8 20 56" />
    </svg>
  );
}

export default function Home() {
  return (
    <>
      {/* ------------------------------ hero ------------------------------ */}
      <section className="hero container">
        <Spotlight />
        <h1 className="hero-equation rise">
          Maker
          <NotEqualIcon />
          Checker
        </h1>
        <p
          className="hero-lede rise rise-2"
          dangerouslySetInnerHTML={{ __html: renderInline(heroLede) }}
        />
        <div className="hero-actions rise rise-3">
          <CopyButton
            text={readme.installCommand}
            variant="primary"
            label="Copy install command"
            copiedText="Copied — paste it into Claude Code"
          />
          <a
            className="hero-github-link"
            href={plugin.homepage}
            target="_blank"
            rel="noopener noreferrer"
          >
            View on GitHub →
          </a>
        </div>
      </section>

      {/* ------------------------- how it works --------------------------- */}
      <section className="section" id="how-it-works">
        <div className="container">
          <p className="eyebrow">The SOP</p>
          <h2 className="section-title">Maker is not checker</h2>
          <div
            className="section-lede prose"
            dangerouslySetInnerHTML={{ __html: howItWorksLedeHtml }}
          />

          <div className="roles-grid">
            {arch.roles.map((role) => (
              <div className="role-card" key={role.role}>
                <GlowingEffect />
                <span className="role-icon">
                  <RoleIcon role={role.role} />
                </span>
                <h3 dangerouslySetInnerHTML={{ __html: renderInline(role.role) }} />
                <p
                  className="role-who"
                  dangerouslySetInnerHTML={{ __html: renderInline(role.who) }}
                />
                <p
                  className="role-job"
                  dangerouslySetInnerHTML={{ __html: renderInline(role.job) }}
                />
                <p
                  className="role-constraint"
                  dangerouslySetInnerHTML={{ __html: renderInline(role.constraint) }}
                />
              </div>
            ))}
          </div>
        </div>

        <div className="container" style={{ marginTop: "4rem" }}>
          <h3 className="section-title" style={{ fontSize: "1.35rem" }}>
            The loop, stage by stage
          </h3>
          <ol className="stage-rail">
            {arch.stages.slice(0, 5).map((stage) => (
              <li className="stage" key={stage.num}>
                <span className="stage-num">{String(stage.num).padStart(2, "0")}</span>
                <div>
                  <h3 dangerouslySetInnerHTML={{ __html: renderInline(stage.title) }} />
                  <p
                    className="stage-summary"
                    dangerouslySetInnerHTML={{ __html: renderInline(stage.summary) }}
                  />
                </div>
              </li>
            ))}
          </ol>
          <p className="components-note">
            …plus {arch.stages.length - 5} more stages (gate, hold, integrate, teardown, audit) in
            the <Link href="/architecture/">full architecture doc</Link>.
          </p>
        </div>
      </section>

      {/* --------------------------- quick start --------------------------- */}
      <section className="section" id="quickstart">
        <div className="container">
          <p className="eyebrow">Quick start</p>
          <h2 className="section-title">Run your first loop</h2>
          <div className="prose" dangerouslySetInnerHTML={{ __html: quickStart }} />
        </div>
      </section>

      {/* --------------------------- requirements -------------------------- */}
      <section className="section" id="requirements">
        <div className="container">
          <p className="eyebrow">Requirements</p>
          <h2 className="section-title">What you need</h2>
          <div className="prose" dangerouslySetInnerHTML={{ __html: requirements }} />
        </div>
      </section>
    </>
  );
}
