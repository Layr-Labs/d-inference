import { Layers, Laptop, Power, RefreshCw, Sparkles } from 'lucide-react';
import type { ReactNode } from 'react';
import type { Snapshot } from '../../../shared/contracts';
import { gigabytes } from '../../models/facts';
import { startModels, type StartMethod } from './startPlan';
import styles from './servingSummary.module.css';

function machineLine({ machine, eligibility }: Snapshot) {
  const storage = eligibility?.checks.find((check) => check.id === 'storage' && check.ok);
  return [
    machine.chip,
    machine.memory_gb && gigabytes(machine.memory_gb),
    storage?.value && `${storage.value} free`,
  ]
    .filter(Boolean)
    .join(' · ');
}

function startingLine(snapshot: Snapshot, method: StartMethod, pinned: string[]) {
  const ids = startModels(snapshot, method, pinned);
  const chosen = snapshot.models.filter((model) => ids.includes(model.id));
  if (!chosen.length) return 'Choose a model in Advanced to start.';
  const names = chosen.map((model) => model.display_name).join(', ');
  const download = chosen
    .filter((model) => !model.downloaded)
    .reduce((total, model) => total + model.size_gb, 0);
  const lead = method === 'autopilot' ? 'Starts with' : 'Serves';
  return download
    ? `${lead} ${names}, downloading ${gigabytes(download)} first.`
    : `${lead} ${names}, already on this Mac.`;
}

// What starting will do, stated only from what the runtime reported.
export function ServingSummary({
  snapshot,
  method,
  pinned,
}: {
  snapshot: Snapshot;
  method: StartMethod;
  pinned: string[];
}) {
  const steps: { icon: ReactNode; text: string }[] = [
    { icon: <Sparkles size={15} />, text: startingLine(snapshot, method, pinned) },
    method === 'autopilot'
      ? {
          icon: <Layers size={15} />,
          text: pinned.length
            ? 'Keeps pinned models loaded and manages the rest as demand changes.'
            : 'Chooses which downloaded models stay in memory as demand changes.',
        }
      : {
          icon: <Layers size={15} />,
          text:
            method === 'local'
              ? 'Runs only for your apps on this Mac’s local endpoint.'
              : 'Keeps these models loaded until you change them.',
        },
    {
      icon: <RefreshCw size={15} />,
      text: snapshot.settings.auto_update
        ? 'Updates on · managed by the native runtime.'
        : 'Updates off · turn them on any time in Updates.',
    },
    { icon: <Power size={15} />, text: 'Stop any time from the app or the menu bar.' },
  ];
  return (
    <section className={styles.summary} aria-label="What happens next">
      <header className={styles.machine}>
        <span className={styles.device}>
          <Laptop size={20} strokeWidth={1.6} />
        </span>
        <span>
          <strong>{snapshot.machine.name}</strong>
          <small>{machineLine(snapshot)}</small>
        </span>
      </header>
      <ul className={styles.plan}>
        {steps.map((step) => (
          <li key={step.text}>
            {step.icon}
            <span>{step.text}</span>
          </li>
        ))}
      </ul>
    </section>
  );
}
