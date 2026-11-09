import { ArrowUpRight } from 'lucide-react';
import type { Snapshot } from '../../../shared/contracts';
import { PairGlyph, type PairMood } from './PairGlyph';
import styles from './cluster.module.css';

type Pair = NonNullable<Snapshot['pair']>;

// The pair's state from this Mac's own files (`Snapshot.pair`), nothing asked over the cable.
const words: Record<NonNullable<Pair['state']>, string> = {
  serving: 'Serving',
  started: 'Started',
  not_running: 'Not running here',
  stopped: 'Stopped',
  unreadable: 'Pairing unreadable',
};
const moods: Record<NonNullable<Pair['state']>, PairMood> = {
  serving: 'serving',
  started: 'starting',
  not_running: 'away',
  stopped: 'stopped',
  unreadable: 'failed',
};

// This Mac's overview, on a Mac in a pair: the pair in one line, and the way to Clusters.
export function PairCard({ pair, onOpen }: { pair: Pair; onOpen: () => void }) {
  const facts = [
    pair.model ?? (pair.state === 'unreadable' ? null : 'No model yet'),
    pair.state ? words[pair.state] : null,
    pair.leads === true ? 'This Mac leads' : pair.leads === false ? 'The other Mac leads' : null,
  ].filter(Boolean);
  return (
    <section className={styles.pairCard} aria-label="Pair">
      <PairGlyph
        mood={pair.state ? moods[pair.state] : 'stopped'}
        className={styles.pairCardGlyph}
      />
      <div>
        <strong>In a pair</strong>
        <span>{facts.join(' · ')}</span>
      </div>
      <button type="button" className="text-link" onClick={onOpen}>
        Clusters <ArrowUpRight size={13} aria-hidden="true" />
      </button>
    </section>
  );
}
