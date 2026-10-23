import { useMemo, useState } from 'react';
import type { NetworkData } from '../../../shared/contracts';
import { compact, count } from '../../format';
import { cellsFrom, macs, regionsFrom } from './geography';
import { GRID_COLS, GRID_ROWS, worldGrid } from './world-grid';
import styles from './leaderboard.module.css';

const tile = (col: number, row: number) => ({
  x: col * 12 + 1,
  y: row * 10 + 1,
  width: 10,
  height: 8,
  rx: 1.5,
});

const land = worldGrid.flatMap((line, row) =>
  [...line].flatMap((cell, col) =>
    cell === '#' ? [<rect key={`${col}:${row}`} {...tile(col, row)} />] : [],
  ),
);

export function NetworkMap({ network }: { network?: NetworkData }) {
  const cells = useMemo(
    () => cellsFrom(regionsFrom(network?.provider_regions)),
    [network?.provider_regions],
  );
  const [hovered, setHovered] = useState('');
  const [selected, setSelected] = useState('');
  const find = (key: string) => cells.find((cell) => cell.key === key);
  const chosen = find(selected);
  const active = find(hovered) ?? chosen;
  return (
    <section className={styles.network} aria-label="Network overview">
      <div className={styles.map}>
        <svg
          viewBox={`0 0 ${GRID_COLS * 12} ${GRID_ROWS * 10}`}
          role="img"
          aria-label="World map of public provider regions"
          onPointerLeave={() => setHovered('')}
        >
          <g className={styles.land}>{land}</g>
          <g className={styles.lit}>
            {cells.map((cell) => (
              <rect
                key={cell.key}
                {...tile(cell.col, cell.row)}
                data-level={cell.level}
                onPointerEnter={() => setHovered(cell.key)}
              >
                <title>{`${cell.label}: ${macs(cell.providers)}`}</title>
              </rect>
            ))}
          </g>
          {active && <rect className={styles.active} {...tile(active.col, active.row)} />}
        </svg>
        <div className={styles.mapCaption}>
          {cells.length ? (
            <>
              <label className={styles.regionPicker}>
                Explore regions
                <select
                  aria-label="Explore provider regions"
                  value={chosen ? selected : ''}
                  onChange={(event) => setSelected(event.target.value)}
                >
                  <option value="">All regions</option>
                  {cells.map((cell) => (
                    <option key={cell.key} value={cell.key}>
                      {`${cell.label}: ${macs(cell.providers)}`}
                    </option>
                  ))}
                </select>
              </label>
              <span>
                {active
                  ? `${macs(active.providers)} · ${active.label}`
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
            <dd>{count(network?.total_macs)}</dd>
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
