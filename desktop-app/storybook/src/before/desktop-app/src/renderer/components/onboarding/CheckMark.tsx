import styles from './scanCard.module.css';

export function CheckMark() {
  return (
    <span className={styles.checkMark} aria-hidden="true">
      <svg viewBox="0 0 32 32">
        <circle cx="16" cy="16" r="14" pathLength={1} />
        <path d="M10.5 16.5l3.8 3.8 7.2-8" pathLength={1} />
      </svg>
    </span>
  );
}
