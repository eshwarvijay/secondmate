/**
 * Scrolling stats strip under the header -- a common, generic marquee-ticker
 * pattern (used across countless sites), not any specific product's design.
 * Content is real build-time data only: plugin version, license, and the
 * live GitHub star count (omitted if the build-time fetch fails -- never a
 * fabricated number). Pure CSS linear-loop animation, no JS, frozen under
 * prefers-reduced-motion per the no-large-moving-object accessibility rule.
 */
export function StatsTicker({
  version,
  mitLicensed,
  stars,
  clones,
}: {
  version: string;
  mitLicensed: boolean;
  stars: number | null;
  clones: number | null;
}) {
  const items = [
    `v${version}`,
    "Claude Code plugin",
    mitLicensed ? "MIT license" : null,
    stars !== null ? `★ ${stars.toLocaleString()} on GitHub` : null,
    clones !== null ? `${clones.toLocaleString()} clones` : null,
    "open source",
  ].filter((x): x is string => x !== null);

  // Duplicate the sequence so the CSS loop can wrap seamlessly.
  const track = [...items, ...items, ...items];

  return (
    <div className="stats-ticker" aria-hidden="true">
      <div className="stats-ticker-track">
        {track.map((item, i) => (
          <span className="stats-ticker-item" key={i}>
            {item}
            <span className="stats-ticker-sep">✦</span>
          </span>
        ))}
      </div>
    </div>
  );
}
