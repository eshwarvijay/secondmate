/**
 * Original hero illustration — a simple sitting creature built from the
 * site's own paw-print mark (app/icon.svg's four toe-circles + palm ellipse),
 * worn here as a chest badge. No external artwork or reference asset; every
 * shape is a plain circle/ellipse/path authored for this component.
 */
export function MascotIllustration({ className }: { className?: string }) {
  return (
    <svg
      className={className ? `mascot ${className}` : "mascot"}
      xmlns="http://www.w3.org/2000/svg"
      viewBox="0 0 220 210"
      fill="none"
      aria-hidden
    >
      {/* tail */}
      <path
        d="M165 150c22-4 34-22 30-42"
        stroke="var(--border-strong)"
        strokeWidth="2"
        strokeLinecap="round"
      />

      {/* body */}
      <ellipse
        cx="108"
        cy="146"
        rx="56"
        ry="48"
        fill="var(--bg-elevated)"
        stroke="var(--border-strong)"
        strokeWidth="2"
      />

      {/* ears */}
      <circle cx="82" cy="46" r="13" fill="var(--bg-elevated)" stroke="var(--border-strong)" strokeWidth="2" />
      <circle cx="134" cy="46" r="13" fill="var(--bg-elevated)" stroke="var(--border-strong)" strokeWidth="2" />

      {/* head */}
      <circle cx="108" cy="74" r="38" fill="var(--bg-elevated)" stroke="var(--border-strong)" strokeWidth="2" />

      {/* face */}
      <circle cx="95" cy="72" r="4" fill="var(--text)" />
      <circle cx="121" cy="72" r="4" fill="var(--text)" />
      <path
        d="M98 88c6 5 14 5 20 0"
        stroke="var(--text-muted)"
        strokeWidth="2"
        strokeLinecap="round"
      />

      {/* chest badge — the repo's own paw mark, same proportions as app/icon.svg */}
      <g fill="var(--accent)" transform="translate(108 140) scale(0.78) translate(-16 -16)">
        <circle cx="8" cy="10.5" r="3" />
        <circle cx="13.2" cy="7.5" r="3" />
        <circle cx="18.8" cy="7.5" r="3" />
        <circle cx="24" cy="10.5" r="3" />
        <ellipse cx="16" cy="20.5" rx="7.6" ry="6.4" />
      </g>
    </svg>
  );
}
