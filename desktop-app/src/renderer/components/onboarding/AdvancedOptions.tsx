import { ChevronDown } from 'lucide-react';
import { useEffect, useId, useRef } from 'react';
import { useReducedMotion } from '../../useReducedMotion';
import type { Snapshot } from '../../../shared/contracts';
import { ModeChoice, type ContributionMode } from './ModeChoice';
import { PinList } from './PinList';
import type { StartMethod } from './startPlan';
import styles from './advancedOptions.module.css';

const pinCopy: Record<StartMethod, { title: string; lead: string; noun: string }> = {
  autopilot: {
    title: 'Keep a model always on',
    lead: 'A pinned model stays loaded, so it’s always ready on this Mac and its local endpoint. Autopilot manages the rest.',
    noun: 'pinned',
  },
  manual: {
    title: 'Models to serve',
    lead: 'These models load when this Mac starts serving and stay until you change them.',
    noun: 'chosen',
  },
  local: {
    title: 'Keep a model always on',
    lead: 'Local only runs just the models you pin, for your apps on this Mac’s local endpoint.',
    noun: 'pinned',
  },
};

export function AdvancedOptions({
  snapshot,
  open,
  onToggle,
  method,
  mode,
  onMode,
  pinned,
  onPinned,
}: {
  snapshot: Snapshot;
  open: boolean;
  onToggle: () => void;
  method: StartMethod;
  mode: ContributionMode;
  onMode: (mode: ContributionMode) => void;
  pinned: string[];
  onPinned: (pinned: string[]) => void;
}) {
  const id = useId();
  const panel = useRef<HTMLDivElement>(null);
  const reduced = useReducedMotion();
  const copy = pinCopy[method];
  useEffect(() => {
    if (open)
      panel.current?.scrollIntoView?.({ block: 'nearest', behavior: reduced ? 'auto' : 'smooth' });
  }, [open, reduced]);
  return (
    <div className={styles.advanced} data-open={open}>
      <button
        className={styles.disclosure}
        aria-expanded={open}
        aria-controls={id}
        onClick={onToggle}
      >
        Advanced
        <ChevronDown size={14} />
      </button>
      {open && (
        <div className={styles.panel} id={id} ref={panel} role="region" aria-label="Advanced">
          <h3>{copy.title}</h3>
          <p>{copy.lead}</p>
          <PinList snapshot={snapshot} pinned={pinned} noun={copy.noun} onChange={onPinned} />
          <h3>How this Mac is used</h3>
          <ModeChoice mode={mode} onChange={onMode} />
        </div>
      )}
    </div>
  );
}
