"use client";

import { useEffect, useRef, useState } from "react";

/** On phones navigation behaves as a modal drawer; desktop remains a landmark. */
export function useSidebarDialog(open: boolean, onClose: () => void) {
  const ref = useRef<HTMLElement>(null);
  const [mobile, setMobile] = useState(false);
  useEffect(() => {
    const media = window.matchMedia("(max-width: 639px)");
    const update = () => setMobile(media.matches);
    update();
    media.addEventListener("change", update);
    return () => media.removeEventListener("change", update);
  }, []);

  useEffect(() => {
    if (!open || !mobile) return;
    const previous = document.activeElement instanceof HTMLElement ? document.activeElement : null;
    const drawer = ref.current;
    const focusable = () => drawer?.querySelectorAll<HTMLElement>('a[href],button:not([disabled]),input:not([disabled]),[tabindex="0"]');
    focusable()?.[0]?.focus();
    const onKeyDown = (event: KeyboardEvent) => {
      if (event.key === "Escape") { event.preventDefault(); onClose(); }
      if (event.key !== "Tab") return;
      const elements = focusable();
      if (!elements?.length) return;
      const first = elements[0];
      const last = elements[elements.length - 1];
      if (event.shiftKey && document.activeElement === first) { event.preventDefault(); last.focus(); }
      else if (!event.shiftKey && document.activeElement === last) { event.preventDefault(); first.focus(); }
    };
    drawer?.addEventListener("keydown", onKeyDown);
    return () => { drawer?.removeEventListener("keydown", onKeyDown); previous?.focus(); };
  }, [mobile, open, onClose]);
  return { ref, mobile };
}
