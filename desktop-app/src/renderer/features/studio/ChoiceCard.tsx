import { useId, type ReactNode } from 'react';
import { Check } from 'lucide-react';
import styles from './studio.module.css';

// One answer of a choice, as a card around a native radio. The radio is named by the title alone;
// the badge, the marker (what is saved), the line and the hint describe it.
export function ChoiceCard({
  name,
  checked,
  disabled = false,
  onSelect,
  title,
  detail,
  badge,
  marker,
  hint,
}: {
  name: string;
  checked: boolean;
  disabled?: boolean;
  onSelect: () => void;
  title: string;
  detail: ReactNode;
  badge?: string;
  marker?: string;
  hint?: string;
}) {
  const id = useId();
  const part = (what: string) => `${id}-${what}`;
  const described = [
    badge && part('badge'),
    marker && part('marker'),
    part('detail'),
    hint && part('hint'),
  ]
    .filter(Boolean)
    .join(' ');
  return (
    <label className={styles.choice} data-checked={checked || undefined}>
      <input
        type="radio"
        name={name}
        checked={checked}
        disabled={disabled}
        onChange={onSelect}
        aria-labelledby={part('title')}
        aria-describedby={described}
      />
      <span className={styles.choiceBody}>
        <span className={styles.choiceHead}>
          <strong id={part('title')}>{title}</strong>
          {badge && (
            <span id={part('badge')} className={styles.badge}>
              {badge}
            </span>
          )}
          {marker && (
            <span id={part('marker')} className={styles.marker}>
              <Check size={12} strokeWidth={2.2} aria-hidden="true" />
              {marker}
            </span>
          )}
        </span>
        <span id={part('detail')} className={styles.detail}>
          {detail}
        </span>
        {hint && (
          <span id={part('hint')} className={styles.hint}>
            {hint}
          </span>
        )}
      </span>
    </label>
  );
}
