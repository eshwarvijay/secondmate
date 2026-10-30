"use client";

/* The loop as a pinned horizontal timeline on desktop: vertical scroll
   scrubs the stages sideways while a progress hairline draws across.
   Below 768px or with reduced motion, CSS lays the same stages out as a
   plain vertical list and this enhancement never runs -- the content is
   fully readable with no JS at all. */

import { useRef } from "react";
import gsap from "gsap";
import { useGSAP } from "@gsap/react";
import { ScrollTrigger } from "gsap/ScrollTrigger";

gsap.registerPlugin(useGSAP);

/* ScrollTrigger reads window/document at registration time, which breaks
   the static export's server pre-render -- register it client-side only. */
if (typeof window !== "undefined") {
  gsap.registerPlugin(ScrollTrigger);
}

export function LoopTimeline({ children }: { children: React.ReactNode }) {
  const root = useRef<HTMLElement | null>(null);

  useGSAP(
    () => {
      const mm = gsap.matchMedia();

      mm.add(
        {
          isDesktop:
            "(min-width: 768px) and (prefers-reduced-motion: no-preference)",
          isMobile:
            "(max-width: 767px) and (prefers-reduced-motion: no-preference)",
        },
        (context) => {
          const { isDesktop, isMobile } = context.conditions as {
            isDesktop: boolean;
            isMobile: boolean;
          };
          const el = root.current;
          if (!el) return;
          const viewport = el.querySelector<HTMLElement>(".loop-viewport");
          const track = el.querySelector<HTMLElement>(".loop-track");
          const fill = el.querySelector<HTMLElement>(".loop-progress-fill");
          const stages = gsap.utils.toArray<HTMLElement>(".loop-stage", el);
          const scaleEl = el.querySelector<HTMLElement>(".loop-scale");

          /* The whole section grows into place as it approaches the
             viewport center -- scale only, never opacity: content the
             user is reading must stay at full density while they read
             it. Scrubbed, so it tracks the user's own scroll. */
          if (scaleEl) {
            gsap.fromTo(
              scaleEl,
              { scale: 0.94 },
              {
                scale: 1,
                ease: "none",
                scrollTrigger: {
                  trigger: el,
                  start: "top bottom",
                  end: "top 45%",
                  scrub: true,
                },
              },
            );
            gsap.fromTo(
              scaleEl,
              { scale: 1 },
              {
                scale: 0.94,
                ease: "none",
                scrollTrigger: {
                  trigger: el,
                  start: "bottom 55%",
                  end: "bottom top",
                  scrub: true,
                  immediateRender: false,
                },
              },
            );
          }

          if (isDesktop && viewport && track && fill) {
            // How far the track must travel for its last stage to arrive.
            const distance = () =>
              Math.max(0, track.offsetWidth - viewport.clientWidth);

            const tl = gsap.timeline({
              scrollTrigger: {
                trigger: el,
                start: "top 15%",
                end: () => "+=" + distance(),
                pin: true,
                scrub: 0.5,
                anticipatePin: 1,
                invalidateOnRefresh: true,
              },
            });

            // The scrub and the progress line are the same motion, tied to
            // one scroll range -- spatial consistency by construction.
            tl.to(track, { x: () => -distance(), ease: "none" }, 0).fromTo(
              fill,
              { scaleX: 0 },
              { scaleX: 1, ease: "none" },
              0,
            );

            // Focus the stage nearest the viewport center while scrubbing:
            // ScrollTrigger only toggles the class; CSS transitions carry
            // the scale/density change so it can retarget mid-motion.
            el.classList.add("focus-active");
            stages.forEach((stage) => {
              ScrollTrigger.create({
                trigger: stage,
                containerAnimation: tl,
                start: "center 70%",
                end: "center 30%",
                toggleClass: { targets: stage, className: "is-focused" },
              });
            });
          }

          if (isMobile) {
            // Same focus effect on the stacked list, driven by vertical
            // scroll -- the stage crossing the screen's center enlarges.
            el.classList.add("focus-active");
            stages.forEach((stage) => {
              ScrollTrigger.create({
                trigger: stage,
                start: "center 65%",
                end: "center 35%",
                toggleClass: { targets: stage, className: "is-focused" },
              });
            });
          }
        },
      );
    },
    { scope: root },
  );

  return (
    <section ref={root} className="section loop-section">
      <div className="loop-scale">{children}</div>
    </section>
  );
}
