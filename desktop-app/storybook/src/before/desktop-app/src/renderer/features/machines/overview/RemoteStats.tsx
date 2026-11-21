import type { ReactNode } from 'react';
import type { Machine } from '../../../../shared/contracts';
import { age, clockTime, compact, count, money } from '../../../format';
import { uptime, type Presence } from './presence';
import styles from './remote.module.css';

interface Tile {
  label: string;
  value: ReactNode;
  exact?: number;
}

function Tiles({ label, caption, tiles }: { label: string; caption: string; tiles: Tile[] }) {
  return (
    <section className={styles.group} aria-label={label}>
      <h3>{caption}</h3>
      <dl className={styles.tiles}>
        {tiles.map((tile) => (
          <div key={tile.label}>
            <dt>{tile.label}</dt>
            <dd title={tile.exact === undefined ? undefined : count(tile.exact)}>{tile.value}</dd>
          </div>
        ))}
      </dl>
    </section>
  );
}

export function RemoteStats({
  machine,
  presence,
  now,
  updateRequired,
}: {
  machine: Machine;
  presence: Presence;
  now: number;
  updateRequired: boolean;
}) {
  const tokens = machine.tokens_24h;
  const total = tokens && tokens.output + (tokens.input ?? 0) + (tokens.cached_input ?? 0);
  return (
    <>
      <Tiles
        label={`${machine.name}’s earnings`}
        caption="Earnings and provider"
        tiles={[
          { label: 'Earned all time', value: money(machine.lifetime_micro_usd) },
          { label: 'Last 24 hours', value: money(machine.day_micro_usd) },
          { label: 'Usage · 7 days', value: money(machine.earnings_micro_usd) },
          {
            label: 'Last paid work',
            value: machine.last_paid_at ? age(machine.last_paid_at) : '—',
          },
          {
            label: 'Online since',
            value:
              presence === 'online' && machine.online_since ? (
                <>
                  {clockTime(machine.online_since, now)}
                  <small>{uptime(now - machine.online_since)}</small>
                </>
              ) : (
                '—'
              ),
          },
          {
            label: 'Provider version',
            value: (
              <>
                {machine.version || '—'}
                {updateRequired && <em className={styles.badge}>Update required</em>}
              </>
            ),
          },
        ]}
      />
      <Tiles
        label="Past 24 hours"
        caption="Requests and tokens served · past 24 hours"
        tiles={[
          { label: 'Requests', value: compact(machine.requests_24h), exact: machine.requests_24h },
          { label: 'Tokens served', value: compact(total), exact: total },
          { label: 'Input tokens', value: compact(tokens?.input), exact: tokens?.input },
          {
            label: 'Cached input tokens',
            value: compact(tokens?.cached_input),
            exact: tokens?.cached_input,
          },
          { label: 'Output tokens', value: compact(tokens?.output), exact: tokens?.output },
        ]}
      />
    </>
  );
}
