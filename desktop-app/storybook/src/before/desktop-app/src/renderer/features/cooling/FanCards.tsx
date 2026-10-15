import type { CoolingData } from '../../../shared/contracts';
import { count } from '../../format';
import { FanGlyph } from '../../components/FanGlyph';
import styles from './cooling.module.css';

export function FanCards({ fans }: { fans: CoolingData['fans'] }) {
  return (
    <ul className={styles.fans} aria-label="Fans">
      {fans.map((fan, i) => (
        <li key={i}>
          <span className={styles.fanName}>
            <FanGlyph rpm={fan.rpm} maxRpm={fan.max_rpm} name={fan.name} />
            {fan.name}
            <small>{fan.rpm > 0 ? 'Spinning' : 'Stopped'}</small>
          </span>
          <strong>
            {count(fan.rpm)} <small>RPM</small>
          </strong>
          <div className="memory-track">
            <span
              style={{
                width: `${fan.max_rpm > 0 ? Math.min(100, (fan.rpm / fan.max_rpm) * 100) : 0}%`,
              }}
            />
          </div>
        </li>
      ))}
    </ul>
  );
}
