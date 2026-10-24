import { ArrowUpRight, LifeBuoy } from 'lucide-react';
import { useCallback, useState } from 'react';
import { createPortal } from 'react-dom';
import type { DesktopAPI } from '../../shared/contracts';
import { api } from '../useBackend';
import { External, Modal } from './UI';
import styles from './help.module.css';

const resources: {
  target: Parameters<DesktopAPI['openExternal']>[0];
  title: string;
  description: string;
}[] = [
  {
    target: 'docs',
    title: 'Read the guide',
    description: 'Setting up, serving, earnings, and troubleshooting.',
  },
  {
    target: 'slack',
    title: 'Ask in Slack',
    description: 'Get help from the Darkbloom team and other providers.',
  },
  {
    target: 'community',
    title: 'Community discussions',
    description: 'Search questions and answers on GitHub, or ask your own.',
  },
];

// The next step for a failure the app can't fix by itself: the guide covers troubleshooting.
export function GetHelp() {
  return <External target="docs">Get help</External>;
}

export function HelpControl({ version }: { version?: string }) {
  const [open, setOpen] = useState(false);
  const close = useCallback(() => setOpen(false), []);
  return (
    <>
      <button
        className={styles.trigger}
        aria-haspopup="dialog"
        aria-label="Help"
        onClick={() => setOpen(true)}
      >
        <LifeBuoy size={18} strokeWidth={1.55} />
        <span>Help</span>
      </button>
      {open &&
        createPortal(
          <Modal title="Help" onClose={close}>
            <ul className={styles.list}>
              {resources.map(({ target, title, description }) => (
                <li key={target}>
                  <button className={styles.item} onClick={() => void api?.openExternal(target)}>
                    <span>
                      <strong>{title}</strong>
                      <small>{description}</small>
                    </span>
                    <ArrowUpRight size={15} />
                  </button>
                </li>
              ))}
            </ul>
            {version && (
              <p className={styles.version}>When you ask, mention Darkbloom {version}.</p>
            )}
          </Modal>,
          document.body,
        )}
    </>
  );
}
