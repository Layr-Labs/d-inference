import styles from './chip.module.css';
export function ChipStatus({ mode, live }: { mode: string; live: boolean }) {
  return (
    <span className={styles.mode} data-live={live}>
      {mode}
    </span>
  );
}
