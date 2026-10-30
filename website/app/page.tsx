import Link from "next/link";
import { CopyButton } from "@/components/CopyButton";
import { HomeHero } from "@/components/HomeHero";
import { LoopTimeline } from "@/components/LoopTimeline";
import { RevealOnScroll } from "@/components/RevealOnScroll";
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

/* Human-readable one-liners for the loop timeline, in stage order. The
   parsed summaries from docs/ARCHITECTURE.md are written for agents (flags,
   script names, verdict enums); these are the same stages told for humans.
   Ordered by stage number -- if a stage is added or reordered in the doc,
   entries fall back to the technical summary rather than showing the wrong
   copy, so keep this list in sync when the stage list changes. */
const stageTaglines = [
  "Six AI models look at your task from different angles, and one merges it all into a single plan.",
  "The task gets sorted: code to ship or a question to answer -- and how careful we need to be.",
  "The maker gets its own isolated workspace. Your main project is never touched.",
  "The maker writes the code, with automatic guards watching every edit.",
  "A different AI model -- one that didn't write the code -- tries its best to break it.",
  "An automated gate re-checks the facts: clean workspace, real tests, actually passing.",
  "Anything risky -- merging, deploying, deleting -- stops here and waits for your explicit yes.",
  "Only a passing review, a green gate, and your approval let the change land.",
  "The temporary workspace is closed and cleaned up, with proof nothing was left behind.",
  "Every decision, verdict, and approval is written to a permanent log you can replay.",
  "What this run learned is fed back, so the next task starts smarter.",
];

/* Animated line icons for the loop stages, in stage order -- the
   heroicons-animated set (MIT), vendored from the shadcn registry into
   components/icons/. They animate subtly on hover. */
import { UserGroupIcon } from "@/components/icons/user-group";
import { ArrowsRightLeftIcon } from "@/components/icons/arrows-right-left";
import { PlusCircleIcon } from "@/components/icons/plus-circle";
import { ShieldCheckIcon } from "@/components/icons/shield-check";
import { CheckCircleIcon } from "@/components/icons/check-circle";
import { LockClosedIcon } from "@/components/icons/lock-closed";
import { PauseCircleIcon } from "@/components/icons/pause-circle";
import { LinkIcon } from "@/components/icons/link";
import { XCircleIcon } from "@/components/icons/x-circle";
import { DocumentTextIcon } from "@/components/icons/document-text";
import { ArrowPathIcon } from "@/components/icons/arrow-path";

const LOOP_ICONS = [
  UserGroupIcon, // 00 plan committee -- many voices
  ArrowsRightLeftIcon, // 01 triage -- the fork
  PlusCircleIcon, // 02 spawn -- a fresh workspace
  ShieldCheckIcon, // 03 implement, guarded
  CheckCircleIcon, // 04 check -- the review
  LockClosedIcon, // 05 gate -- nothing slips through
  PauseCircleIcon, // 06 hold -- waits for a human
  LinkIcon, // 07 integrate -- the merge
  XCircleIcon, // 08 teardown -- closed out
  DocumentTextIcon, // 09 audit trail -- the record
  ArrowPathIcon, // 10 lesson feedback -- the loop closes
];

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
      <HomeHero>
        <Spotlight />
        <h1 className="hero-equation">
          <span className="hero-word-mask">
            <span data-hero-word>Maker</span>
          </span>
          <NotEqualIcon />
          <span className="hero-word-mask">
            <span data-hero-word>Checker</span>
          </span>
        </h1>
        <p
          className="hero-lede"
          dangerouslySetInnerHTML={{ __html: renderInline(heroLede) }}
        />
        <div className="hero-actions">
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
      </HomeHero>

      {/* ------------------------- how it works --------------------------- */}
      <RevealOnScroll className="section" id="how-it-works">
        <div className="container">
          <p className="eyebrow">The SOP</p>
          <h2 className="section-title">Maker is not checker</h2>
          <div
            className="section-lede prose"
            dangerouslySetInnerHTML={{ __html: howItWorksLedeHtml }}
          />

          <ol className="roles-list">
            {arch.roles.map((role, i) => (
              <li className="role-row" key={role.role} data-reveal>
                <span className="role-index">{String(i + 1).padStart(2, "0")}</span>
                <div className="role-id">
                  <h3 dangerouslySetInnerHTML={{ __html: renderInline(role.role) }} />
                  <p
                    className="role-who"
                    dangerouslySetInnerHTML={{ __html: renderInline(role.who) }}
                  />
                </div>
                <div className="role-detail">
                  <p
                    className="role-job"
                    dangerouslySetInnerHTML={{ __html: renderInline(role.job) }}
                  />
                  <p
                    className="role-constraint"
                    dangerouslySetInnerHTML={{ __html: renderInline(role.constraint) }}
                  />
                </div>
              </li>
            ))}
          </ol>
        </div>

      </RevealOnScroll>

      {/* ---------------------------- the loop ---------------------------- */}
      <LoopTimeline>
        <div className="container">
          <p className="eyebrow">The loop</p>
          <h2 className="section-title">Stage by stage</h2>
        </div>
        <div className="loop-viewport container">
          <ol className="loop-track">
            {arch.stages.map((stage) => {
              const Icon = LOOP_ICONS[stage.num] ?? ArrowPathIcon;
              return (
                <li className="loop-stage" key={stage.num}>
                  <span className="loop-glyph">
                    <Icon size={28} />
                  </span>
                  <span className="stage-num">{String(stage.num).padStart(2, "0")}</span>
                  <h3 dangerouslySetInnerHTML={{ __html: renderInline(stage.title) }} />
                  <p
                    className="stage-summary"
                    dangerouslySetInnerHTML={{
                      __html: renderInline(stageTaglines[stage.num] ?? stage.summary),
                    }}
                  />
                </li>
              );
            })}
          </ol>
          <div className="loop-progress" aria-hidden="true">
            <div className="loop-progress-fill" />
          </div>
          <p className="components-note">
            Full detail in the <Link href="/architecture/">architecture doc</Link>.
          </p>
        </div>
      </LoopTimeline>

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
