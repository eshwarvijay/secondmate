/**
 * Subtle warm glow above the hero headline.
 * Adapted from Aceternity UI's Spotlight (https://ui.aceternity.com/components/spotlight,
 * MIT-licensed copy-paste component): Tailwind classes replaced by plain CSS in
 * globals.css, and the white fill swapped for the site's --accent palette.
 * Pure SVG + a one-shot CSS entrance — no JavaScript, no dependencies.
 */
export function Spotlight({ className, fill }: { className?: string; fill?: string }) {
  return (
    <svg
      className={className ? `spotlight ${className}` : "spotlight"}
      xmlns="http://www.w3.org/2000/svg"
      viewBox="0 0 3787 2842"
      fill="none"
      aria-hidden
    >
      <g filter="url(#spotlight-blur)">
        <ellipse
          cx="1924.71"
          cy="273.501"
          rx="1924.71"
          ry="273.501"
          transform="matrix(-0.822377 -0.568943 -0.568943 0.822377 3631.88 2291.09)"
          fill={fill ?? "#e8b339"}
          fillOpacity="0.15"
        />
      </g>
      <defs>
        <filter
          id="spotlight-blur"
          x="0.860352"
          y="0.838989"
          width="3785.16"
          height="2840.26"
          filterUnits="userSpaceOnUse"
          colorInterpolationFilters="sRGB"
        >
          <feFlood floodOpacity="0" result="BackgroundImageFix" />
          <feBlend mode="normal" in="SourceGraphic" in2="BackgroundImageFix" result="shape" />
          <feGaussianBlur stdDeviation="151" result="effect1_foregroundBlur_1065_8" />
        </filter>
      </defs>
    </svg>
  );
}
