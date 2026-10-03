import type { CoolingData } from '../../../../shared/contracts';
import { count } from '../../../format';
import { FanGlyph, rpmLabel } from '../../../components/FanGlyph';
import styles from './overview.module.css';

const ratio = (fan: CoolingData['fans'][number]) => (fan.max_rpm > 0 ? fan.rpm / fan.max_rpm : 0);

function fanReading(cooling?: CoolingData) {
  if (!cooling) return { value: 'Checking…', detail: 'Reading fan sensors.' };
  if (cooling.error || cooling.mode === 'unavailable')
    return { value: 'Unavailable', detail: cooling.error || 'Fan status is unavailable.' };
  if (!cooling.fans.length) return { value: 'No fans', detail: 'macOS manages cooling.' };
  const { fans } = cooling;
  const lead = fans.reduce((fastest, fan) => (ratio(fan) > ratio(fastest) ? fan : fastest));
  const spinning = fans.filter((fan) => fan.rpm > 0);
  const average = spinning.reduce((sum, fan) => sum + fan.rpm, 0) / (spinning.length || 1);
  const share =
    fans.length > 1
      ? `${fans.map((fan) => `${fan.name} ${count(fan.rpm)}`).join(' · ')} RPM`
      : lead.max_rpm > 0 && `${Math.round(ratio(lead) * 100)}% of max`;
  return {
    value: spinning.length ? `Spinning · ${rpmLabel(average)}` : 'Stopped',
    detail: [
      share,
      cooling.supported && cooling.mode === 'manual' ? 'Provider cooling' : 'macOS managed',
    ]
      .filter(Boolean)
      .join(' · '),
    glyph: {
      rpm: spinning.length ? lead.rpm : 0,
      maxRpm: lead.max_rpm,
      name: fans.length > 1 ? 'Fans' : fans[0].name,
    },
  };
}

export function FanHealth({ cooling }: { cooling?: CoolingData }) {
  const reading = fanReading(cooling);
  return (
    <div className={styles.cell}>
      <div className={styles.cellLabel}>
        <span>Fans</span>
        {cooling?.temperature != null && (
          <span title="GPU temperature">{Math.round(cooling.temperature)}°C GPU</span>
        )}
      </div>
      <strong>
        <FanGlyph {...reading.glyph} size={15} />
        {reading.value}
      </strong>
      <small>{reading.detail}</small>
    </div>
  );
}
