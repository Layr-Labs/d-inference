import { useEffect, useRef, useState, useSyncExternalStore, type ComponentType, type ReactNode } from 'react';
import type { Meta, StoryObj } from '@storybook/react-vite';
import { userEvent, within } from 'storybook/test';
import { Modal as ModalBefore } from '../src/before/desktop-app/src/renderer/components/UI';
import { Modal as ModalAfter } from '../src/after/desktop-app/src/renderer/components/UI';
import { ChipStage as ChipBefore } from '../src/before/desktop-app/src/renderer/features/home/chip/ChipStage';
import { ChipStage as ChipAfter } from '../src/after/desktop-app/src/renderer/features/home/chip/ChipStage';
import { Compare, Observed } from './support/Compare';
import { resetBridges, type Version } from './support/bridge';
import { previewBackend } from './support/fixtures';

const meta: Meta = { title: 'Second pass/Keyboard and screen readers', beforeEach: () => resetBridges() };
export default meta;
type Story = StoryObj;

// One dialog at a time: the fixed dialog listens to keys on the whole document.
let active: Version | null = null;
const listeners = new Set<() => void>();
const setActive = (version: Version | null) => {
  active = version;
  listeners.forEach((listener) => listener());
};
const useActive = () =>
  useSyncExternalStore(
    (listener) => (listeners.add(listener), () => void listeners.delete(listener)),
    () => active,
  );

function describeFocus() {
  const el = document.activeElement as HTMLElement | null;
  return el && el !== document.body
    ? `“${(el.getAttribute('aria-label') || el.textContent || '').trim()}”`
    : 'the page body';
}

type ModalType = ComponentType<{ title: string; children: ReactNode; onClose: () => void }>;

function RefreshingDialog({ version, Modal }: { version: Version; Modal: ModalType }) {
  const open = useActive() === version;
  const [tick, setTick] = useState(0);
  const [focus, setFocus] = useState('—');
  useEffect(() => {
    // Like the app's state pushes: the page re-renders, passing the dialog a new onClose.
    const timer = setInterval(() => setTick((n) => n + 1), 700);
    const sample = setInterval(() => {
      setFocus(describeFocus());
    }, 150);
    return () => {
      clearInterval(timer);
      clearInterval(sample);
    };
  }, []);
  return (
    <div className="sb-demo">
      <button className="button" onClick={() => setActive(version)}>
        Open “Turn off automatic updates?”
      </button>
      <p className="sb-observed">
        Dialog: <b>{open ? 'open' : 'closed'}</b> · re-renders: {tick}
        <br />
        Keyboard focus now: <b>{open ? focus : '—'}</b>
        <br />
        {/* Written by the play step, which measures after waiting. */}
        <b data-result />
      </p>
      {open && (
        <Modal title="Turn off automatic updates?" onClose={() => setActive(null)}>
          <p>Darkbloom won't update the provider automatically.</p>
          <div className="dialog-actions">
            <button className="button">Keep enabled</button>
            <button className="button danger">Turn off</button>
          </div>
        </Modal>
      )}
    </div>
  );
}

export const DialogFocusYank: Story = {
  name: '#1466 Dialogs pulling focus back every few seconds',
  beforeEach: () => setActive(null),
  play: async ({ canvasElement }) => {
    for (const pane of canvasElement.querySelectorAll<HTMLElement>('.sb-pane')) {
      const scope = within(pane);
      await userEvent.click(scope.getByRole('button', { name: /Open/ }));
      scope.getByRole('button', { name: 'Turn off' }).focus();
      await new Promise((resolve) => setTimeout(resolve, 2800));
      pane.querySelector('[data-result]')!.textContent =
        `2.5 s after focusing “Turn off”, focus is on ${describeFocus()}.`;
    }
  },
  render: () => (
    <Compare
      pr={1466}
      title="Every dialog pulled keyboard focus back to “Close dialog”"
      wrong={
        <p>
          The dialog re-ran its setup whenever it received a new close handler, which callers
          create on every render, and the app re-renders on every state push. So about every two
          seconds focus jumped back to <b>Close dialog</b>: pressing Enter a moment late closed
          the dialog instead of choosing an action.
        </p>
      }
      fixed={
        <p>
          The setup runs once per open dialog. The play step opens each dialog, focuses{' '}
          <b>Turn off</b>, and leaves it for 2.5 s while the page keeps re-rendering. Watch where
          focus ends up.
        </p>
      }
      before={<RefreshingDialog version="before" Modal={ModalBefore} />}
      after={<RefreshingDialog version="after" Modal={ModalAfter} />}
      height={320}
    />
  ),
};

function Announcements({ children }: { children: ReactNode }) {
  const ref = useRef<HTMLDivElement>(null);
  const [changes, setChanges] = useState(0);
  const [last, setLast] = useState('');
  const [since] = useState(Date.now());
  const [, rerender] = useState(0);
  useEffect(() => {
    const live = ref.current?.querySelector('[aria-live]');
    if (!live) return;
    setLast(live.textContent ?? '');
    const observer = new MutationObserver(() => {
      setChanges((n) => n + 1);
      setLast(live.textContent ?? '');
    });
    observer.observe(live, { childList: true, characterData: true, subtree: true });
    const clock = setInterval(() => rerender((n) => n + 1), 1000);
    return () => {
      observer.disconnect();
      clearInterval(clock);
    };
  }, []);
  return (
    <div ref={ref}>
      <Observed>
        Screen-reader announcements: <b>{changes}</b> in {Math.round((Date.now() - since) / 1000)} s
        <br />
        Last: “{last}”
      </Observed>
      {children}
    </div>
  );
}

export const ChipAnnouncements: Story = {
  name: '#1478 Home chip announcements',
  loaders: [async () => ({ backend: await previewBackend() })],
  render: (_, { loaded }) => {
    const state = { ...loaded.backend.state!, state: 'running' as const, observed_at: Date.now() / 1000 };
    return (
      <Compare
        pr={1478}
        title="Home re-announced a 20-word summary every five seconds"
        wrong={
          <p>
            The chip's live region held numbers that change every second (requests, tokens per
            second, GPU busy), so a screen reader repeated the whole sentence every five seconds
            for as long as Home was open.
          </p>
        }
        fixed={
          <p>
            Only the chip's name and state are announced; the numbers stay readable on demand.
            The counters show how often each version announces while this page is visible (the
            simulated chip pauses in hidden tabs). Measured in headless Chrome: Before 6 in 29 s,
            After 0.
          </p>
        }
        before={
          <Announcements>
            <ChipBefore state={state} preview />
          </Announcements>
        }
        after={
          <Announcements>
            <ChipAfter state={state} preview />
          </Announcements>
        }
        stack
      />
    );
  },
};

function NavigationFocus({ version }: { version: Version }) {
  const [result, setResult] = useState('Running: focus “View earnings” on Home and activate it…');
  return (
    <div className="sb-framed">
      <div className="sb-frame-box">
        <iframe
          title={`Full app ${version}`}
          src={`iframe.html?id=internal-full-app--${version}&viewMode=story`}
          onLoad={async (event) => {
            const frame = event.currentTarget.contentWindow!;
            await new Promise((resolve) => setTimeout(resolve, 3500));
            const button = [...frame.document.querySelectorAll<HTMLButtonElement>('main button')].find(
              (b) => b.textContent?.includes('View earnings'),
            );
            button?.focus();
            button?.click();
            await new Promise((resolve) => setTimeout(resolve, 1200));
            const el = frame.document.activeElement as HTMLElement | null;
            const where =
              !el || el === frame.document.body
                ? 'the page body (nothing)'
                : `the “${el.textContent?.trim()}” ${el.tagName.toLowerCase()}`;
            const title = frame.document.title.endsWith('Darkbloom')
              ? `“${frame.document.title}”`
              : 'not set by the app';
            setResult(`After opening Earnings, focus is on ${where}. Window title: ${title}.`);
          }}
        />
      </div>
      <p className="sb-observed">{result}</p>
    </div>
  );
}

export const FocusAfterNavigation: Story = {
  name: '#1479 Focus after opening another page',
  render: () => (
    <Compare
      pr={1479}
      title="Opening a page from a button dropped keyboard focus"
      wrong={
        <p>
          The button that opened a page (View earnings, Explore Stats, opening a Mac, onboarding
          Start…) disappears with the old page, so focus fell to the page body: keyboard users
          started over from the top and screen readers said nothing. The window title was always
          “Darkbloom”.
        </p>
      }
      fixed={
        <p>
          When focus is lost, it moves to the new page's heading, and the window is named after
          the page. Each pane runs the whole app in its own frame.
        </p>
      }
      before={<NavigationFocus version="before" />}
      after={<NavigationFocus version="after" />}
    />
  ),
};
