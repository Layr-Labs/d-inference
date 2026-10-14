import { useEffect, useRef, type RefObject } from 'react';

const restoreTargets = new Map<HTMLElement, HTMLElement | null>();

function topmostModal() {
  let top: HTMLElement | undefined;
  for (const element of restoreTargets.keys()) {
    if (!element.isConnected) continue;
    // Backdrops share a z-index. Portals can be above a modal whose effect ran later.
    if (!top || top.compareDocumentPosition(element) & Node.DOCUMENT_POSITION_FOLLOWING)
      top = element;
  }
  return top;
}

export function useModalFocus(ref: RefObject<HTMLElement | null>, onClose: () => void) {
  // State pushes replace callers' callbacks, but must not re-run setup and reset focus.
  const close = useRef(onClose);
  close.current = onClose;
  useEffect(() => {
    const element = ref.current;
    if (!element) return;
    restoreTargets.set(element, document.activeElement as HTMLElement | null);
    const active = () => topmostModal() === element;
    if (active()) element.querySelector<HTMLButtonElement>('button')?.focus();

    const keydown = (event: KeyboardEvent) => {
      if (!active() || event.defaultPrevented) return;
      if (event.key === 'Escape') {
        event.preventDefault();
        close.current();
        return;
      }
      if (event.key !== 'Tab') return;
      const controls = [
        ...element.querySelectorAll<HTMLElement>(
          'button:not([disabled]), input:not([disabled]), select:not([disabled]), textarea:not([disabled]), a[href], summary, [tabindex="0"]',
        ),
      ];
      const first = controls[0] ?? element;
      const last = controls.at(-1) ?? element;
      const focused = document.activeElement;
      if (focused === element || !element.contains(focused)) {
        event.preventDefault();
        (event.shiftKey ? last : first).focus();
      } else if (event.shiftKey && focused === first) {
        event.preventDefault();
        last.focus();
      } else if (!event.shiftKey && focused === last) {
        event.preventDefault();
        first.focus();
      }
    };
    // Sign-in replaces its controls as it advances. Only the visible dialog may recover focus.
    const keep = new MutationObserver(() => {
      if (active() && !element.contains(document.activeElement)) element.focus();
    });
    keep.observe(element, { childList: true, subtree: true });
    document.addEventListener('keydown', keydown);
    return () => {
      keep.disconnect();
      document.removeEventListener('keydown', keydown);
      const previous = restoreTargets.get(element);
      restoreTargets.delete(element);
      // A lower dialog can disappear first, or mount while the portal is already open. Keep
      // restoration pointing to the original trigger rather than a control in a closed dialog.
      for (const [dialog, target] of restoreTargets) {
        if (target && element.contains(target)) restoreTargets.set(dialog, previous ?? null);
      }
      const focused = document.activeElement;
      if (focused && focused !== document.body && !element.contains(focused)) return;
      const next = topmostModal();
      if (previous?.isConnected && (!next || next.contains(previous))) previous.focus();
      else next?.focus();
    };
  }, [ref]);
}
