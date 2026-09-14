"use client";

import Script from "next/script";
import { useEffect } from "react";

declare global {
  interface Window {
    va?: (...args: unknown[]) => void;
    vaq?: unknown[][];
  }
}

export function Analytics() {
  useEffect(() => {
    if (
      process.env.NODE_ENV !== "production" ||
      process.env.NEXT_PUBLIC_DISABLE_ANALYTICS === "1"
    )
      return;
    window.va =
      window.va ||
      ((...args: unknown[]) => {
        (window.vaq = window.vaq || []).push(args);
      });
    const observer = new IntersectionObserver(
      (entries) => {
        entries.forEach((entry) => {
          if (!entry.isIntersecting) return;
          window.va?.("event", {
            name: "section_viewed",
            data: { section: entry.target.getAttribute("data-section") },
          });
          observer.unobserve(entry.target);
        });
      },
      { threshold: 0.3 },
    );
    document
      .querySelectorAll("[data-section]")
      .forEach((section) => observer.observe(section));
    function trackClick(event: MouseEvent) {
      if (!(event.target instanceof Element)) return;
      const link = event.target.closest("a");
      if (!link) return;
      const section = link.closest("[data-section]");
      window.va?.("event", {
        name: "cta_click",
        data: {
          section:
            section?.getAttribute("data-section") ||
            (link.closest("header") ? "nav" : "footer"),
          label: link.textContent?.trim(),
        },
      });
    }
    document.addEventListener("click", trackClick);
    return () => {
      observer.disconnect();
      document.removeEventListener("click", trackClick);
    };
  }, []);
  if (
    process.env.NODE_ENV !== "production" ||
    process.env.NEXT_PUBLIC_DISABLE_ANALYTICS === "1"
  )
    return null;
  return (
    <>
      <Script src="/analytics.js" strategy="afterInteractive" />
      <Script src="/_vercel/insights/script.js" strategy="afterInteractive" />
    </>
  );
}
