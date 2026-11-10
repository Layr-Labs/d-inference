import { useId } from 'react';
import { useReducedMotion } from '../../useReducedMotion';
import styles from './cluster.module.css';

// Two Macs joined by one Thunderbolt cable, drawn in the app's line style. `mood` follows the
// pair: `invite` (not paired yet), `serving` (requests flow both ways), `starting`, `stopped`,
// `away` (the other Mac doesn't answer) and `failed`. Decorative: the page says the state in words.
export type PairMood = 'invite' | 'serving' | 'starting' | 'stopped' | 'away' | 'failed';

const cable = 'M100 52 C 118 52, 116 72, 130 72 S 142 52, 160 52';
const bolt =
  'M4 14a1 1 0 0 1-.78-1.63l9.9-10.2a.5.5 0 0 1 .86.46l-1.92 6.02A1 1 0 0 0 13 10h7a1 1 0 0 1 .78 1.63l-9.9 10.2a.5.5 0 0 1-.86-.46l1.92-6.02A1 1 0 0 0 11 14z';

function Mac({ x, dim, led }: { x: number; dim?: boolean; led: string }) {
  return (
    <g className={styles.glyphMac} data-dim={dim || undefined}>
      <rect x={x} y={30} width={84} height={46} rx={11} />
      <path d={`M${x + 12} 31.5h60`} className={styles.glyphTop} />
      <circle cx={x + 16} cy={62} r={1.7} />
      <circle cx={x + 24} cy={62} r={1.7} />
      <path d={`M${x + 34} 62h14`} />
      <circle cx={x + 71} cy={62} r={2.4} className={styles.glyphLed} data-led={led} />
    </g>
  );
}

export function PairGlyph({ mood, className }: { mood: PairMood; className?: string }) {
  const reduced = useReducedMotion();
  // React's ids carry characters a URL fragment would escape (`«r1»`); the cable's `href` must
  // match its id as written.
  const id = useId().replace(/[^A-Za-z0-9_-]/g, '');
  const moving = !reduced && (mood === 'serving' || mood === 'invite');
  const led =
    mood === 'serving' ? 'on' : mood === 'starting' ? 'wait' : mood === 'failed' ? 'fail' : 'off';
  return (
    <svg
      className={`${styles.glyph} ${className ?? ''}`}
      data-mood={mood}
      viewBox="0 0 260 96"
      aria-hidden="true"
      focusable="false"
    >
      <Mac x={14} led={led} />
      <Mac x={162} dim={mood === 'away'} led={mood === 'away' ? 'off' : led} />
      <path id={`cable-${id}`} d={cable} className={styles.glyphCable} />
      <rect x={97} y={48.5} width={8} height={7} rx={2} className={styles.glyphPlug} />
      <rect x={155} y={48.5} width={8} height={7} rx={2} className={styles.glyphPlug} />
      <circle cx={130} cy={72} r={10} className={styles.glyphBadge} />
      <path d={bolt} transform="translate(124 66) scale(0.5)" className={styles.glyphBolt} />
      {moving && (
        <>
          <circle r={2.6} className={styles.glyphPulse}>
            <animateMotion dur={mood === 'invite' ? '3.6s' : '2.2s'} repeatCount="indefinite">
              <mpath href={`#cable-${id}`} />
            </animateMotion>
          </circle>
          {mood === 'serving' && (
            <circle r={2.6} className={styles.glyphPulse}>
              <animateMotion
                dur="2.2s"
                begin="1.1s"
                repeatCount="indefinite"
                keyPoints="1;0"
                keyTimes="0;1"
                calcMode="linear"
              >
                <mpath href={`#cable-${id}`} />
              </animateMotion>
            </circle>
          )}
        </>
      )}
    </svg>
  );
}
