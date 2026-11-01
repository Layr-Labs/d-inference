import type { CSSProperties } from 'react';
import { Fan } from 'lucide-react';
import type { CoolingData } from '../../../../shared/contracts';
import { coolingStale } from '../../cooling/status';
import styles from './fanStatus.module.css';

export function FanStatus({ cooling, onOpen }: { cooling?: CoolingData; onOpen: () => void }) {
  const known =
    cooling?.supported && !cooling.error && !coolingStale(cooling) && cooling.enabled != null;
  const enabled = known && cooling.enabled;
  const temperature =
    known && cooling.temperature != null && Number.isFinite(cooling.temperature)
      ? cooling.temperature
      : null;
  const heat =
    !enabled && temperature != null ? Math.max(0, Math.min(1, (temperature - 60) / 30)) : 0;
  const label = !cooling
    ? 'Checking fans'
    : !known
      ? 'Fan status unavailable'
      : enabled
        ? 'Auto fan on'
        : 'Auto fan off';
  return (
    <button
      className={styles.status}
      data-enabled={!!enabled}
      data-heat={heat > 0 || undefined}
      style={heat > 0 ? ({ '--heat-hue': 45 * (1 - heat) } as CSSProperties) : undefined}
      onClick={onOpen}
      title="Open Cooling"
      aria-label={`${label}${temperature != null ? ` · ${Math.round(temperature)}°C` : ''}. Open Cooling`}
    >
      <Fan size={14} />
      {label}
      {temperature != null && <span>{Math.round(temperature)}°C</span>}
    </button>
  );
}
