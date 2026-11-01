import { CHIP_VARIANTS, type ChipVariant } from './variant';
import styles from './chip.module.css';

export function VariantSwitch({
  value,
  onChange,
}: {
  value: ChipVariant;
  onChange: (variant: ChipVariant) => void;
}) {
  return (
    <div className={styles.switch} role="group" aria-label="Chip style">
      {CHIP_VARIANTS.map(({ id, label }) => (
        <button key={id} aria-pressed={value === id} onClick={() => onChange(id)}>
          {label}
        </button>
      ))}
    </div>
  );
}
