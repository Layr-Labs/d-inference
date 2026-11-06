import { useEffect, useLayoutEffect, useRef, type ReactNode } from 'react';
import type { Route, Snapshot } from '../../src/after/desktop-app/src/shared/contracts';
import { previewAPI as previewBefore } from '../../src/before/desktop-app/src/renderer/preview';
import { previewAPI as previewAfter } from '../../src/after/desktop-app/src/renderer/preview';
import { bridges, type Version } from './bridge';

const flag = 'darkbloom.onboardingComplete';

/**
 * For stories that render the real App: mark onboarding complete (so neither onboarding nor the
 * startup screen shows once the first snapshot arrives) and serve each version's own
 * development-preview fixtures through its bridge (`macosVersion` is what `api.system()` reports;
 * 27.0 by default). Returns the cleanup for `beforeEach`.
 */
export function shellFixtures({
  macosVersion,
  snapshot,
}: {
  macosVersion?: string;
  /** Adjusts each `state` read (both versions), e.g. to show This Mac stopped. */
  snapshot?: (state: Snapshot) => Snapshot;
} = {}) {
  const previous = localStorage.getItem(flag);
  localStorage.setItem(flag, '1');
  const reader = (read: (resource: never) => Promise<unknown>) => async (resource: string) => {
    const value = await read(resource as never);
    return snapshot && resource === 'state' ? snapshot(value as Snapshot) : value;
  };
  bridges.before.reset({ read: reader(previewBefore.read), macosVersion });
  bridges.after.reset({ read: reader(previewAfter.read), macosVersion });
  return () => {
    if (previous === null) localStorage.removeItem(flag);
    else localStorage.setItem(flag, previous);
  };
}

/**
 * Opens `route` in the App inside it once it has mounted, through the bridge's onNavigate (the
 * same path the menu bar uses). App subscribes in its own effect, which runs before this one.
 */
export function AtRoute({ version, route, children }: { version: Version; route: Route; children: ReactNode }) {
  useEffect(() => {
    if (route !== 'home') bridges[version].navigate(route);
  }, [version, route]);
  return <>{children}</>;
}

/**
 * HelpControl portals its dialog to document.body (fixed, full window). Move it into this pane,
 * whose surface transform contains fixed elements, so it covers the After pane only. React still
 * removes it from body when it closes, so body.removeChild is taught to find it here; on unmount
 * it goes back to body first.
 */
export function DockDialogs({ children }: { children: ReactNode }) {
  const ref = useRef<HTMLDivElement>(null);
  useLayoutEffect(() => {
    const host = ref.current!;
    const body = document.body;
    const moved = new Set<Node>();
    const original = body.removeChild;
    body.removeChild = function <T extends Node>(this: HTMLElement, child: T): T {
      if (moved.has(child) && child.parentNode !== body) {
        moved.delete(child);
        child.parentNode?.removeChild(child);
        return child;
      }
      return original.call(this, child) as T;
    };
    const dock = () => {
      for (const dialog of body.querySelectorAll<HTMLElement>(':scope > .modal-backdrop')) {
        moved.add(dialog);
        host.append(dialog);
        host.closest('.sb-surface')?.scrollTo(0, 0);
      }
    };
    const observer = new MutationObserver(dock);
    observer.observe(body, { childList: true });
    return () => {
      observer.disconnect();
      for (const dialog of moved) if (dialog.parentNode === host) body.append(dialog);
      body.removeChild = original;
    };
  }, []);
  return <div ref={ref}>{children}</div>;
}

