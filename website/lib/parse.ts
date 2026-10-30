import { listRepoDir, readRepoFile, requireMarker } from "./repo";

/**
 * Parsers that extract real content from the repo's own documentation.
 * Every parser throws (failing `next build`) when the source doc changes
 * shape, instead of silently rendering stale or empty sections.
 */

/* ------------------------------------------------------------------ */
/* README.md                                                           */
/* ------------------------------------------------------------------ */

export interface ReadmeContent {
  /** The <em> tagline, split on <br/> into display lines, HTML stripped. */
  taglineLines: string[];
  /** Intro paragraphs between the badges and "## ⚡ Quick start" (raw markdown). */
  intro: string;
  /** Body of "## ⚡ Quick start" without the heading (raw markdown). */
  quickStart: string;
  /** First fenced code block inside Quick start (the install commands). */
  installCommand: string;
  /** Intro prose of "## 📦 Requirements" up to the first <details> block (raw markdown). */
  requirements: string;
  /** True when the README ends with an MIT license note. */
  mitLicensed: boolean;
}

function sectionBetween(md: string, startMarker: string, endMarker: string, where: string): string {
  const start = requireMarker(md, startMarker, where) + startMarker.length;
  const end = requireMarker(md.slice(start), endMarker, where) + start;
  return md.slice(start, end).trim();
}

export function getReadme(): ReadmeContent {
  const md = readRepoFile("README.md");
  const where = "README.md";

  const emMatch = md.match(/<em>([\s\S]*?)<\/em>/);
  if (!emMatch) {
    throw new Error("website: README.md tagline (<em>…</em>) not found");
  }
  const taglineLines = emMatch[1]
    .split(/<br\s*\/?>/i)
    .map((line) => line.replace(/<[^>]+>/g, "").trim())
    .filter(Boolean);
  if (taglineLines.length === 0) {
    throw new Error("website: README.md tagline parsed to zero lines");
  }

  const introStart = requireMarker(md, "**secondmate** is a Claude Code plugin", where);
  const introEnd = requireMarker(md, "## ⚡ Quick start", where);
  const intro = md.slice(introStart, introEnd).trim();

  const quickStart = sectionBetween(md, "## ⚡ Quick start", "## 🔁 How it works", where);

  const fence = quickStart.match(/```(?:sh|bash|shell)?\s*\n([\s\S]*?)```/);
  if (!fence) {
    throw new Error("website: no install code block found in README.md quick start");
  }
  const installCommand = fence[1].trim();

  const reqSection = sectionBetween(md, "## 📦 Requirements", "<details>", where);

  return {
    taglineLines,
    intro,
    quickStart,
    installCommand,
    requirements: reqSection,
    mitLicensed: /\[MIT\]\(LICENSE\)/.test(md),
  };
}

/* ------------------------------------------------------------------ */
/* docs/ARCHITECTURE.md                                                */
/* ------------------------------------------------------------------ */

export interface Stage {
  num: number;
  title: string;
  /** First sentence of the stage body, italics note stripped (raw inline markdown). */
  summary: string;
  /** The "*Guards against:*" text (raw inline markdown), trailing period stripped. Empty when the stage documents none. */
  guardsAgainst: string;
}

export interface Role {
  role: string;
  who: string;
  job: string;
  constraint: string;
}

export interface ArchitectureDoc {
  /** Full markdown source, for the /architecture page. */
  markdown: string;
  stages: Stage[];
  roles: Role[];
}

function collapseWs(text: string): string {
  return text.replace(/\s+/g, " ").trim();
}

/** Cut at the first sentence boundary (". " followed by a non-space or EOL). */
function firstSentence(text: string): string {
  const match = text.match(/\.\s/);
  if (!match || match.index === undefined) return text;
  return text.slice(0, match.index + 1);
}

export function getArchitecture(): ArchitectureDoc {
  const md = readRepoFile("docs", "ARCHITECTURE.md");
  const where = "docs/ARCHITECTURE.md";

  /* --- stages --- */
  const stageSectionStart = requireMarker(md, "## Stage by stage", where);
  const stageSectionEnd = requireMarker(md, "## Scope guard", where);
  const stageSection = md.slice(stageSectionStart, stageSectionEnd);

  // Split on stage headings: "0. **Plan Committee** *(note)*." / "1. **Triage.** …"
  const headingRe = /^(\d+)\.\s+\*\*([^*]+?)\.?\*\*\s*/gm;
  const headings: { num: number; title: string; index: number; length: number }[] = [];
  let m: RegExpExecArray | null;
  while ((m = headingRe.exec(stageSection)) !== null) {
    headings.push({
      num: Number(m[1]),
      title: m[2].replace(/\.$/, "").trim(),
      index: m.index,
      length: m[0].length,
    });
  }
  if (headings.length < 5) {
    throw new Error(
      `website: expected at least 5 numbered stages in ${where}, found ${headings.length}`,
    );
  }
  headings.forEach((h, i) => {
    if (h.num !== headings[0].num + i) {
      throw new Error(
        `website: stage numbering in ${where} is not sequential (found ${h.num} at position ${i}) — a stage was added, removed, or mis-parsed`,
      );
    }
  });

  const stages: Stage[] = headings.map((h, i) => {
    const bodyStart = h.index + h.length;
    const bodyEnd = i + 1 < headings.length ? headings[i + 1].index : stageSection.length;
    const body = stageSection.slice(bodyStart, bodyEnd);

    const guardsMatch = body.match(/\*Guards against:\*\s*([\s\S]*?)$/);
    // Not every stage documents a "Guards against" line (e.g. Teardown, Audit
    // trail) — that's a property of the real doc, not a parse failure.
    const guardsAgainst = guardsMatch
      ? collapseWs(guardsMatch[1]).replace(/\.$/, "")
      : "";

    const beforeGuards = guardsMatch ? body.slice(0, guardsMatch.index) : body;
    // Drop the italic stage note, e.g. "*(runs unconditionally …)*."
    const prose = collapseWs(beforeGuards.replace(/^\*\([^*]*\)\*\.?\s*/, ""));
    const summary = firstSentence(prose);
    if (!summary) {
      throw new Error(`website: stage ${h.num} (${h.title}) parsed to an empty summary`);
    }

    return { num: h.num, title: h.title, summary, guardsAgainst };
  });

  /* --- roles table --- */
  const rolesSection = sectionBetween(md, "## Roles", "## The loop", where);
  const roleRows = rolesSection
    .split("\n")
    .map((line) => line.trim())
    .filter((line) => line.startsWith("|"))
    .map((line) =>
      line
        .replace(/^\|/, "")
        .replace(/\|$/, "")
        .split("|")
        .map((cell) => cell.trim()),
    )
    .filter(
      (cells) =>
        cells.length === 4 && !/^-+$/.test(cells[0].replace(/[\s:]/g, "")) && cells[0] !== "Role",
    );
  if (roleRows.length < 3) {
    throw new Error(`website: expected the Roles table in ${where}, found ${roleRows.length} rows`);
  }
  const roles: Role[] = roleRows.map(([role, who, job, constraint]) => ({
    role,
    who,
    job,
    constraint,
  }));

  return { markdown: md, stages, roles };
}

/* ------------------------------------------------------------------ */
/* bin/ script listing                                                 */
/* ------------------------------------------------------------------ */

export interface BinScript {
  file: string;
  /** One-line description parsed from the script's own header, no trailing period. */
  description: string;
}

const SCRIPT_EXTENSIONS = new Set([".sh", ".py", ".ts"]);

function cutSentence(text: string): string {
  // Real sentence boundary: ". " followed by an uppercase letter or "#".
  const hard = /\. (?=[A-Z#])/.exec(text);
  if (hard) return text.slice(0, hard.index + 1);
  // Weaker boundary, only accepted once the text is already long enough to
  // stand alone (avoids cutting "audit/flow.md and …" mid-phrase).
  const soft = /\. (?=[a-z])/.exec(text);
  if (soft && soft.index >= 80) return text.slice(0, soft.index + 1);
  return text;
}

/** Lines of the leading comment/docstring block, prefixes stripped, up to the first blank line. */
function headerLines(file: string, head: string): string[] {
  let raw: string[] = [];
  if (file.endsWith(".ts")) {
    const block = head.match(/\/\*\*([\s\S]*?)\*\//);
    if (block) raw = block[1].split("\n").map((l) => l.replace(/^\s*\* ?/, ""));
  } else if (file.endsWith(".py")) {
    const start = head.indexOf('"""');
    if (start !== -1) {
      const end = head.indexOf('"""', start + 3);
      raw = head.slice(start + 3, end === -1 ? start + 1500 : end).split("\n");
    }
  }
  if (raw.length === 0) {
    const lines = head.split("\n");
    for (let i = 1; i < lines.length; i++) {
      if (!lines[i].startsWith("#")) break;
      raw.push(lines[i].replace(/^#\s?/, ""));
    }
  }
  const firstNonBlank = raw.findIndex((l) => l.trim() !== "");
  const trimmed = firstNonBlank === -1 ? [] : raw.slice(firstNonBlank);
  const blank = trimmed.findIndex((l) => l.trim() === "");
  return (blank === -1 ? trimmed : trimmed.slice(0, blank)).map((l) => l.trim());
}

const DROP_PREFIX =
  /^(ponytail:|(Usage|Env|Exit|State|Prints|Args|Options|Returns|Reads|Writes):)/i;

function isUsageLine(line: string): boolean {
  if (DROP_PREFIX.test(line)) return true;
  // "foo.sh --flag …" at line start (but keep the "foo.sh -- description" line)
  if (/^[\w./-]+\.(sh|py|ts)\s/.test(line) && !/\s--\s/.test(line)) return true;
  // "… | foo.sh --flag …" inline
  if (/[\w./-]+\.(sh|py|ts)\s+--\S/.test(line)) return true;
  return false;
}

/** Extract the "<name> -- <description>" line every bin/ script carries in its header. */
function parseDescription(file: string, head: string): string {
  const lines = headerLines(file, head).filter((l) => !isUsageLine(l));
  const nameIdx = lines.findIndex((l) => /^[\w./-]+\s+--\s+/.test(l));

  let text: string;
  if (nameIdx !== -1) {
    const first = lines[nameIdx].replace(/^[\w./-]+\s+--\s+/, "");
    text = [first, ...lines.slice(nameIdx + 1)].join(" ");
  } else if (lines.length > 0) {
    text = lines.join(" ");
  } else {
    throw new Error(`website: bin/${file} has no parseable description in its header`);
  }

  text = cutSentence(collapseWs(text));
  if (text.length > 180) text = text.slice(0, 177).replace(/\s+\S*$/, "") + "…";
  return text.replace(/\.$/, "");
}

export function getBinScripts(): BinScript[] {
  const entries = listRepoDir("bin");
  const files = entries
    .filter((e) => e.isFile() && SCRIPT_EXTENSIONS.has(e.name.slice(e.name.lastIndexOf("."))))
    .map((e) => e.name)
    .sort();

  if (files.length < 10) {
    throw new Error(`website: expected many scripts in bin/, found ${files.length}`);
  }

  return files.map((file) => ({
    file,
    description: parseDescription(file, readRepoFile("bin", file).slice(0, 5000)),
  }));
}

/**
 * The handful of components the landing page highlights, in loop order.
 * Only the *selection* is curated — every description is parsed from the
 * script's own header, so wording can never drift from the real thing.
 */
const HIGHLIGHTED = [
  "plan-committee.sh",
  "new-worktree.sh",
  "launch-checker.sh",
  "verdict.py",
  "verify-gate.sh",
  "hold.py",
  "merge-sequencer.sh",
  "reason.sh",
  "doctor.sh",
];

export function getHighlightedScripts(): { highlighted: BinScript[]; totalCount: number } {
  const all = getBinScripts();
  const byFile = new Map(all.map((s) => [s.file, s]));
  const highlighted = HIGHLIGHTED.map((file) => {
    const script = byFile.get(file);
    if (!script) {
      throw new Error(`website: highlighted component bin/${file} no longer exists`);
    }
    return script;
  });
  return { highlighted, totalCount: all.length };
}
