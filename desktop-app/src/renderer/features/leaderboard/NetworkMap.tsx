import { useMemo, useState } from 'react';
import type { NetworkData } from '../../../shared/contracts';
import { compact } from '../../format';
import { regionsFrom } from './data';
import { GRID_COLS, GRID_ROWS, worldGrid } from './world-grid';
import styles from './leaderboard.module.css';

const land = worldGrid.flatMap((line, row) =>
  [...line].flatMap((cell, col) =>
    cell === '#'
      ? [
          <rect
            key={`${col}:${row}`}
            x={col * 12 + 1}
            y={row * 10 + 1}
            width={10}
            height={8}
            rx={1.5}
          />,
        ]
      : [],
  ),
);

export function NetworkMap({ network }: { network?: NetworkData }) {
  const regions = useMemo(
    () => regionsFrom(network?.provider_regions),
    [network?.provider_regions],
  );
  const [selected, setSelected] = useState('');
  const cells = useMemo(() => {
    const grouped = new Map<string, { count: number; label: string }>();
    for (const r of regions) {
      const key = `${r.col}:${r.row}`;
      const prior = grouped.get(key);
      grouped.set(key, {
        count: (prior?.count || 0) + r.providers,
        label: prior ? `${prior.label}; ${r.name}, ${r.country}` : `${r.name}, ${r.country}`,
      });
    }
    return [...grouped].map(([key, cell]) => ({ key, ...cell }));
  }, [regions]);
  const hovered = cells.find((cell) => cell.key === selected);
  return (
    <section className={styles.network} aria-label="Network overview">
      <div className={styles.map}>
        <svg
          viewBox={`0 0 ${GRID_COLS * 12} ${GRID_ROWS * 10}`}
          role="img"
          aria-label="World map of public provider regions"
          onPointerLeave={() => setSelected('')}
        >
          <g className={styles.land}>{land}</g>
          <g className={styles.lit}>
            {cells.map((cell) => {
              const [col, row] = cell.key.split(':').map(Number);
              return (
                <rect
                  key={cell.key}
                  x={col * 12 + 1}
                  y={row * 10 + 1}
                  width={10}
                  height={8}
                  rx={1.5}
                  opacity={cell.count >= 40 ? 1 : cell.count >= 10 ? 0.75 : 0.5}
                  onPointerEnter={() => setSelected(cell.key)}
                >
                  <title>
                    {cell.label}: {cell.count} Macs
                  </title>
                </rect>
              );
            })}
          </g>
        </svg>
        <div className={styles.mapCaption}>
          {regions.length ? (
            <>
              <label className={styles.regionPicker}>
                Explore regions
                <select
                  aria-label="Explore provider regions"
                  value={selected}
                  onChange={(event) => setSelected(event.target.value)}
                >
                  <option value="">All regions</option>
                  {cells.map((cell) => (
                    <option key={cell.key} value={cell.key}>
                      {cell.label}: {cell.count} Macs
                    </option>
                  ))}
                </select>
              </label>
              <span>
                {hovered
                  ? `${hovered.count.toLocaleString()} Macs · ${hovered.label}`
                  : 'Approximate public locations'}
              </span>
            </>
          ) : (
            <span>Location data unavailable</span>
          )}
        </div>
      </div>
      <div className={styles.networkNumbers}>
        <h2>A world of compute</h2>
        <dl>
          <div>
            <dt>Macs connected</dt>
            <dd>{compact(network?.total_macs)}</dd>
          </div>
          <div>
            <dt>Tokens processed</dt>
            <dd>{compact(network?.total_tokens)}</dd>
          </div>
        </dl>
        <span className={styles.freshness}>
          {network?.error
            ? 'Last known totals · reconnecting'
            : network
              ? 'Refreshes every 30 seconds'
              : 'Connecting to the network'}
        </span>
      </div>
    </section>
  );
}
