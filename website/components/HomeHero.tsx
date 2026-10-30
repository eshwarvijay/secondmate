"use client";

/* Hero entrance, built from scratch on standard GSAP patterns:
   masked word reveal, hairlines drawing in, near-scale fade for the mark.
   Every value is a deliberate motion decision (see the timeline below);
   the ease curve is the site's own --ease-out token. */

import { useRef } from "react";
import gsap from "gsap";
import { useGSAP } from "@gsap/react";
import { CustomEase } from "gsap/CustomEase";

gsap.registerPlugin(useGSAP, CustomEase);

/* Same curve as the --ease-out design token in globals.css:
   strong ease-out, instant perceived response, long soft landing. */
CustomEase.create("hero-out", "0.23, 1, 0.32, 1");

export function HomeHero({ children }: { children: React.ReactNode }) {
  const root = useRef<HTMLElement | null>(null);

  useGSAP(
    () => {
      /* Reduced motion: the hero is simply there on first paint.
         A page load is not a state change the user needs bridged. */
      if (window.matchMedia("(prefers-reduced-motion: reduce)").matches) return;

      const tl = gsap.timeline({ defaults: { ease: "hero-out" } });

      tl
        // Hairlines draw themselves in from the top, one after another.
        .fromTo(
          ".hero-line",
          { scaleY: 0 },
          { scaleY: 1, duration: 1.1, stagger: 0.08, transformOrigin: "top center" },
          0,
        )
        // Headline words rise out of their masks with a hint of rotation.
        // 70ms stagger: each word lands while the previous is still moving.
        .fromTo(
          "[data-hero-word]",
          { yPercent: 115, rotation: 3 },
          {
            yPercent: 0,
            rotation: 0,
            duration: 1.0,
            stagger: 0.07,
            transformOrigin: "left bottom",
          },
          0.2,
        )
        // The ≠ mark fades in at near-full scale -- never scale(0):
        // nothing in the real world appears from nothing.
        .fromTo(
          ".hero-equation-symbol",
          { scale: 0.9, opacity: 0 },
          { scale: 1, opacity: 1, duration: 0.5 },
          0.55,
        )
        // Lede and actions follow: small travel, opacity + transform only.
        .fromTo(
          ".hero-lede",
          { y: 14, opacity: 0 },
          { y: 0, opacity: 1, duration: 0.7 },
          0.6,
        )
        .fromTo(
          ".hero-actions",
          { y: 14, opacity: 0 },
          { y: 0, opacity: 1, duration: 0.7 },
          0.75,
        );
    },
    { scope: root },
  );

  return (
    <section ref={root} className="hero container">
      <div className="hero-lines" aria-hidden="true">
        <span className="hero-line" />
        <span className="hero-line" />
        <span className="hero-line" />
        <span className="hero-line" />
        <span className="hero-line" />
      </div>
      {children}
    </section>
  );
}
