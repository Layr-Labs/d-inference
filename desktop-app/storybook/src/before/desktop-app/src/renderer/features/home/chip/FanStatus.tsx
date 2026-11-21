import { Fan } from 'lucide-react';
import type { CoolingData } from '../../../../shared/contracts';
import styles from './fanStatus.module.css';

export function FanStatus({ cooling, onOpen }: { cooling?: CoolingData; onOpen: () => void }) {
  const stale = cooling?.observed_at != null && Date.now() / 1000 - cooling.observed_at > 60;
  const known = cooling?.supported && !cooling.error && !stale && cooling.enabled != null;
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
      style={heat > 0 ? { color: `hsl(${45 * (1 - heat)} 80% 58%)` } : undefined}
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
