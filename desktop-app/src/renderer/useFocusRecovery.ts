import { useEffect, useRef } from 'react';

/**
 * After `key` changes (a new page, Mac or onboarding step), the control that had focus is often
 * gone, and focus falls to the page body: keyboard users restart from the top and screen readers
 * announce nothing. Move focus to the new content's heading in that case. Focus that survived the
 * change (a sidebar button, a tab) is left where it is.
 */
export function useFocusRecovery(key: string, heading: () => HTMLElement | null | undefined) {
  const first = useRef(true);
  useEffect(() => {
    const initial = first.current;
    first.current = false;
    const frame = requestAnimationFrame(() => {
      if (initial) return;
      const active = document.activeElement;
      if (active && active !== document.body) return;
      const target = heading();
      if (!target) return;
      if (!target.hasAttribute('tabindex')) target.setAttribute('tabindex', '-1');
      target.focus({ preventScroll: true });
    });
    return () => cancelAnimationFrame(frame);
    // The callback reads the DOM after render; only the key decides when to run.
  }, [key]);
}
