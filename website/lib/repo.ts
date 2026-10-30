import fs from "node:fs";
import path from "node:path";

/**
 * Build-time access to the secondmate repo itself.
 *
 * Every piece of documentation content on this site is read straight from the
 * real files in the repository root (README.md, docs/ARCHITECTURE.md, bin/,
 * .claude-plugin/plugin.json) while `next build` runs. Nothing is copied into
 * components by hand, so the site cannot silently drift from the real docs:
 * if a marker this module relies on disappears, the build fails loudly.
 *
 * This module is server-only — it runs inside Server Components / generateMetadata
 * during the static export.
 */

const REPO_ROOT = path.resolve(process.cwd(), "..");

export function repoPath(...segments: string[]): string {
  return path.join(REPO_ROOT, ...segments);
}

export function readRepoFile(...segments: string[]): string {
  const file = repoPath(...segments);
  try {
    return fs.readFileSync(file, "utf8");
  } catch (err) {
    throw new Error(
      `website: required repo file is missing: ${path.relative(REPO_ROOT, file)} (${String(err)})`,
    );
  }
}

export function listRepoDir(...segments: string[]): fs.Dirent[] {
  const dir = repoPath(...segments);
  try {
    return fs.readdirSync(dir, { withFileTypes: true });
  } catch (err) {
    throw new Error(
      `website: required repo directory is missing: ${path.relative(REPO_ROOT, dir)} (${String(err)})`,
    );
  }
}

export interface PluginMeta {
  name: string;
  version: string;
  description: string;
  homepage: string;
}

/**
 * Live GitHub star count, fetched at build time from the public,
 * unauthenticated repos API. Build-time network calls can fail (offline CI,
 * rate limits), so this never fails the build -- it returns null and the
 * caller just omits the stat rather than showing a fabricated number.
 */
export async function getGithubStars(homepage: string): Promise<number | null> {
  const match = homepage.match(/github\.com\/([^/]+)\/([^/]+?)\/?$/);
  if (!match) return null;
  try {
    const res = await fetch(`https://api.github.com/repos/${match[1]}/${match[2]}`, {
      headers: { Accept: "application/vnd.github+json" },
    });
    if (!res.ok) return null;
    const data = (await res.json()) as { stargazers_count?: unknown };
    return typeof data.stargazers_count === "number" ? data.stargazers_count : null;
  } catch {
    return null;
  }
}

/**
 * Real clone count, tracked in the repo itself by .github/workflows/
 * clone-count.yml (runs weekly, Mondays -- GitHub's traffic API only
 * retains 14 days, so this file is the accumulated persistent total).
 * Same badge data README.md already renders; never a fabricated number.
 */
export function getCloneCount(): number | null {
  try {
    const raw = readRepoFile(".github", "badge-clones.json");
    const parsed = JSON.parse(raw) as { message?: unknown };
    const n = Number(parsed.message);
    return Number.isFinite(n) ? n : null;
  } catch {
    return null;
  }
}

export function getPluginMeta(): PluginMeta {
  const raw = readRepoFile(".claude-plugin", "plugin.json");
  const parsed = JSON.parse(raw) as Partial<PluginMeta>;
  for (const key of ["name", "version", "description", "homepage"] as const) {
    if (!parsed[key] || typeof parsed[key] !== "string") {
      throw new Error(`website: .claude-plugin/plugin.json is missing "${key}"`);
    }
  }
  return parsed as PluginMeta;
}

/** Fail the build when a parser expected a marker that no longer exists. */
export function requireMarker(haystack: string, marker: string, where: string): number {
  const idx = haystack.indexOf(marker);
  if (idx === -1) {
    throw new Error(
      `website: could not find marker ${JSON.stringify(marker)} in ${where}. ` +
        `The source doc changed shape — update website/lib/parse.ts to match.`,
    );
  }
  return idx;
}
