import styles from './leaderboard.module.css';

// Symmetric pixel marks from Kaido's desktop reference, stable for each public alias.
export function ProviderMark({ name }: { name: string }) {
  const seed = [...name].reduce((value, char) => (value * 31 + char.charCodeAt(0)) >>> 0, 7);
  return (
    <span className={styles.mark} aria-hidden="true">
      <svg viewBox="0 0 32 32">
        {Array.from({ length: 25 }, (_, i) => {
          const row = Math.floor(i / 5),
            column = i % 5;
          return (seed >>> (row * 3 + Math.min(column, 4 - column))) & 1 ? (
            <rect
              key={i}
              x={4 + column * 5}
              y={4 + row * 5}
              width="4"
              height="4"
              rx="1"
              fill="currentColor"
            />
          ) : null;
        })}
      </svg>
    </span>
  );
}
