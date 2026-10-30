"use client";

/* Once-only scroll reveals for content sections. Elements marked with
   [data-reveal] inside this section fade/slide in as they enter the
   viewport -- small travel, strong ease-out, 50ms stagger per batch.
   Without JS or with reduced motion, content is simply visible. */

import { useRef } from "react";
import gsap from "gsap";
import { useGSAP } from "@gsap/react";
import { ScrollTrigger } from "gsap/ScrollTrigger";
import { CustomEase } from "gsap/CustomEase";

gsap.registerPlugin(useGSAP, CustomEase);

/* ScrollTrigger reads window/document at registration time, which breaks
   the static export's server pre-render -- register it client-side only. */
if (typeof window !== "undefined") {
  gsap.registerPlugin(ScrollTrigger);
}

// Same curve as the --ease-out design token; self-contained per component.
CustomEase.create("hero-out", "0.23, 1, 0.32, 1");

export function RevealOnScroll({
  children,
  className,
  id,
}: {
  children: React.ReactNode;
  className?: string;
  id?: string;
}) {
  const root = useRef<HTMLElement | null>(null);

  useGSAP(
    () => {
      if (window.matchMedia("(prefers-reduced-motion: reduce)").matches) return;

      const targets = gsap.utils.toArray<HTMLElement>("[data-reveal]");
      if (targets.length === 0) return;

      gsap.set(targets, { y: 16, opacity: 0 });

      ScrollTrigger.batch(targets, {
        start: "top 88%",
        once: true,
        onEnter: (batch) =>
          gsap.to(batch, {
            y: 0,
            opacity: 1,
            duration: 0.7,
            ease: "hero-out",
            stagger: 0.05,
            overwrite: true,
          }),
      });
    },
    { scope: root },
  );

  return (
    <section ref={root} className={className} id={id}>
      {children}
    </section>
  );
}
