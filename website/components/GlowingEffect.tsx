"use client";

import { memo, useCallback, useEffect, useRef } from "react";

/**
 * Pointer-following border glow for cards.
 * Adapted from Aceternity UI's GlowingEffect
 * (https://ui.aceternity.com/components/glowing-effect, MIT-licensed
 * copy-paste component), with three adaptations for this site:
 *  - motion/react's animate() replaced by a small rAF tween, so no new
 *    dependency is added to a static docs site
 *  - Tailwind classes replaced by plain CSS in globals.css (.glow-effect)
 *  - the multicolor gradient replaced by the site's --accent palette
 *
 * Purely additive: renders an aria-hidden, pointer-events-none layer whose
 * --active/--start custom properties drive a masked conic border arc.
 */

interface GlowingEffectProps {
  /** Angular width (deg) of the visible arc. */
  spread?: number;
  /** Distance (px) beyond the card where the pointer still counts as "near". */
  proximity?: number;
  /** Fraction of the card where the pointer is "inside" and the glow hides. */
  inactiveZone?: number;
  /** Seconds the arc takes to swing to a new pointer position. */
  movementDuration?: number;
}

export const GlowingEffect = memo(function GlowingEffect({
  spread = 30,
  proximity = 48,
  inactiveZone = 0.01,
  movementDuration = 1.4,
}: GlowingEffectProps) {
  const containerRef = useRef<HTMLDivElement>(null);
  const lastPosition = useRef({ x: 0, y: 0 });
  const frameRef = useRef(0);
  const tweenRef = useRef(0);

  const handleMove = useCallback(
    (e?: PointerEvent) => {
      const element = containerRef.current;
      if (!element) return;
      cancelAnimationFrame(frameRef.current);
      frameRef.current = requestAnimationFrame(() => {
        const { left, top, width, height } = element.getBoundingClientRect();
        const mouseX = e?.clientX ?? lastPosition.current.x;
        const mouseY = e?.clientY ?? lastPosition.current.y;
        if (e) lastPosition.current = { x: mouseX, y: mouseY };

        const center = [left + width * 0.5, top + height * 0.5];
        const distanceFromCenter = Math.hypot(mouseX - center[0], mouseY - center[1]);
        const inactiveRadius = 0.5 * Math.min(width, height) * inactiveZone;
        if (distanceFromCenter < inactiveRadius) {
          element.style.setProperty("--active", "0");
          return;
        }

        const isActive =
          mouseX > left - proximity &&
          mouseX < left + width + proximity &&
          mouseY > top - proximity &&
          mouseY < top + height + proximity;
        element.style.setProperty("--active", isActive ? "1" : "0");
        if (!isActive) return;

        const currentAngle = parseFloat(element.style.getPropertyValue("--start")) || 0;
        const targetAngle =
          (180 * Math.atan2(mouseY - center[1], mouseX - center[0])) / Math.PI + 90;
        const angleDiff = ((targetAngle - currentAngle + 180) % 360) - 180;
        tweenAngle(
          currentAngle,
          currentAngle + angleDiff,
          movementDuration * 1000,
          (v) => element.style.setProperty("--start", String(v)),
          tweenRef,
        );
      });
    },
    [inactiveZone, proximity, movementDuration],
  );

  useEffect(() => {
    if (window.matchMedia("(prefers-reduced-motion: reduce)").matches) return;

    const handleScroll = () => handleMove();
    const handlePointerMove = (e: PointerEvent) => handleMove(e);
    window.addEventListener("scroll", handleScroll, { passive: true });
    document.body.addEventListener("pointermove", handlePointerMove, { passive: true });
    return () => {
      cancelAnimationFrame(frameRef.current);
      cancelAnimationFrame(tweenRef.current);
      window.removeEventListener("scroll", handleScroll);
      document.body.removeEventListener("pointermove", handlePointerMove);
    };
  }, [handleMove]);

  return (
    <div
      ref={containerRef}
      className="glow-effect"
      style={{ "--spread": spread } as React.CSSProperties}
      aria-hidden
    />
  );
});

/**
 * Minimal rAF tween replacing motion/react's animate() for the --start angle.
 * easeOutCubic is visually indistinguishable from the original
 * cubic-bezier(0.16, 1, 0.3, 1) for a slow angle drift.
 */
function tweenAngle(
  from: number,
  to: number,
  duration: number,
  onUpdate: (v: number) => void,
  rafRef: React.RefObject<number>,
) {
  cancelAnimationFrame(rafRef.current);
  const start = performance.now();
  const step = (now: number) => {
    const t = Math.min(1, (now - start) / duration);
    onUpdate(from + (to - from) * (1 - Math.pow(1 - t, 3)));
    if (t < 1) rafRef.current = requestAnimationFrame(step);
  };
  rafRef.current = requestAnimationFrame(step);
}
