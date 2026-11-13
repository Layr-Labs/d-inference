import { Layers, Laptop, Power, RefreshCw, Sparkles } from 'lucide-react';
import type { ReactNode } from 'react';
import type { Snapshot } from '../../../shared/contracts';
import { gigabytes } from '../../models/facts';
import { pairModel, startModels, type StartMethod } from './startPlan';
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
  // On the Mac that follows, or while the pair loads, the runtime says only `started`: Start serving
  // makes sure it serves there, and starts nothing (#1908's review).
  if (snapshot.pair)
    return snapshot.pair.state === 'serving'
      ? `Keeps the pair serving ${pairModel(snapshot.pair)}, on both Macs.`
      : snapshot.pair.state === 'started'
        ? `Makes sure the pair serves ${pairModel(snapshot.pair)}, on both Macs.`
        : `Starts the pair with ${pairModel(snapshot.pair)}, on both Macs.`;
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
            ? 'Keeps the models you choose in memory and manages the rest as demand changes.'
            : 'Chooses which downloaded models stay in memory as demand changes.',
        }
      : {
          icon: <Layers size={15} />,
          text: snapshot.pair
            ? 'The pair keeps its model loaded until you change it.'
            : 'Keeps these models loaded until you change them.',
        },
    {
      icon: <RefreshCw size={15} />,
      text: snapshot.settings.auto_update
        ? 'Automatic updates on.'
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
