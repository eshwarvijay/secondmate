import Link from "next/link";
import { CopyButton } from "@/components/CopyButton";
import { GlowingEffect } from "@/components/GlowingEffect";
import { Spotlight } from "@/components/Spotlight";
import { getReadme, getArchitecture, getHighlightedScripts } from "@/lib/parse";
import { getPluginMeta } from "@/lib/repo";
import { renderMarkdown, renderInline } from "@/lib/markdown";

/* All content below is parsed at build time from the repo's own files:
   README.md, docs/ARCHITECTURE.md, .claude-plugin/plugin.json and bin/. */

const plugin = getPluginMeta();
const readme = getReadme();
const arch = getArchitecture();
const { highlighted, totalCount } = getHighlightedScripts();

const introParagraphs = readme.intro.split(/\n\n+/);
const heroLede = introParagraphs[0];
const howItWorksLede = introParagraphs.slice(1).join("\n\n");

const quickStart = (await renderMarkdown(readme.quickStart)).html;
const requirements = (await renderMarkdown(readme.requirements)).html;
const howItWorksLedeHtml = (await renderMarkdown(howItWorksLede)).html;

export default function Home() {
  const [taglineMain, ...taglineRest] = readme.taglineLines;

  return (
    <>
      {/* ------------------------------ hero ------------------------------ */}
      <section className="hero container">
        <Spotlight />
        <div className="hero-meta rise">
          <span className="pill">
            <span className="dot" aria-hidden />v{plugin.version}
          </span>
          <span className="pill">Claude Code plugin</span>
        </div>
        <h1 className="hero-title rise rise-1">
          {taglineMain}
          {taglineRest.length > 0 && (
            <>
              <br />
              <span className="dim">{taglineRest.join(" ")}</span>
            </>
          )}
        </h1>
        <p
          className="hero-lede rise rise-2"
          dangerouslySetInnerHTML={{ __html: renderInline(heroLede) }}
        />
        <div className="rise rise-3">
          <div className="install-block">
            <div className="codeblock" data-lang="sh">
              <pre>
                <code>{readme.installCommand}</code>
              </pre>
            </div>
            <CopyButton text={readme.installCommand} label="Copy install commands" />
          </div>
          <div className="hero-actions">
            <Link className="button button-primary" href="/architecture/">
              Read the architecture
            </Link>
            <a
              className="button button-ghost"
              href={plugin.homepage}
              target="_blank"
              rel="noopener noreferrer"
            >
              View on GitHub
            </a>
          </div>
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

      {/* --------------------------- components --------------------------- */}
      <section className="section" id="components">
        <div className="container">
          <p className="eyebrow">Components</p>
          <h2 className="section-title">Scripts own mechanics, agents own judgment</h2>
          <p className="section-lede">
            Every guard in the loop is a real, deterministic script in <code>bin/</code> — the
            descriptions below are parsed from each script&rsquo;s own header at build time, so they
            can&rsquo;t drift from reality.
          </p>
          <div className="components-grid">
            {highlighted.map((script) => (
              <a
                className="component-card"
                key={script.file}
                href={`${plugin.homepage}/blob/main/bin/${script.file}`}
                target="_blank"
                rel="noopener noreferrer"
              >
                <GlowingEffect />
                <p className="component-name">bin/{script.file}</p>
                <p className="component-desc">{script.description}.</p>
              </a>
            ))}
          </div>
          <p className="components-note">
            …plus {totalCount - highlighted.length} more scripts in{" "}
            <a href={`${plugin.homepage}/tree/main/bin`} target="_blank" rel="noopener noreferrer">
              bin/
            </a>{" "}
            — the full component map lives in the{" "}
            <Link href="/architecture/">architecture doc</Link>.
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
