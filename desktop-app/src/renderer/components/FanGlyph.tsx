import type { CSSProperties } from 'react';
import { Fan } from 'lucide-react';
import { count } from '../format';
import { useReducedMotion } from '../useReducedMotion';
import styles from './fanGlyph.module.css';

const IDLE_TURN = 2.4;
const MAX_TURN = 0.45;

export const rpmLabel = (rpm: number) => `${count(rpm)} RPM`;

// Seconds per rotation, or null when the fan is not turning. The scale is perceptual, not literal.
export function fanTurnSeconds(rpm: number, maxRpm: number): number | null {
  if (!(rpm > 0)) return null;
  const ratio = maxRpm > 0 ? Math.min(1, rpm / maxRpm) : 0.5;
  return Number((IDLE_TURN - (IDLE_TURN - MAX_TURN) * ratio).toFixed(2));
}

export function FanGlyph({
  rpm,
  maxRpm,
  name = 'Fan',
  size = 18,
  strokeWidth = 1.6,
}: {
  rpm?: number;
  maxRpm?: number;
  name?: string;
  size?: number;
  strokeWidth?: number;
}) {
  const reduced = useReducedMotion();
  const turn = rpm === undefined ? null : fanTurnSeconds(rpm, maxRpm ?? 0);
  const label =
    rpm === undefined
      ? `${name} speed not reported`
      : turn === null
        ? `${name} stopped`
        : `${name} spinning at ${rpmLabel(rpm)}`;
  const animate = turn !== null && !reduced;
  return (
    <span
      role="img"
      aria-label={label}
      title={label}
      className={styles.glyph}
      data-spinning={turn !== null}
      data-animate={animate}
      style={animate ? ({ '--fan-turn': `${turn}s` } as CSSProperties) : undefined}
    >
      <Fan size={size} strokeWidth={strokeWidth} aria-hidden="true" />
    </span>
  );
}
