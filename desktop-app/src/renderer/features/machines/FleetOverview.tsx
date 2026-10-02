import { useState } from 'react';
import { ArrowUpRight, Laptop, Monitor, Search, RotateCw } from 'lucide-react';
import type { Machine } from '../../../shared/contracts';
import type { BackendState } from '../../useBackend';
import { money } from '../../format';
import { Button, Empty, Header, Status } from '../../components/UI';
import { useInsights } from '../insights/useInsights';
import { EarningsTimeline } from '../insights/EarningsTimeline';
import styles from './machines.module.css';

export function FleetOverview({
  backend,
  machines,
  select,
  onEarnings,
}: {
  backend: BackendState;
  machines: Machine[];
  select: (id: string) => void;
  onEarnings: () => void;
}) {
  const [query, setQuery] = useState('');
  const [filter, setFilter] = useState('all');
  const { data, error } = useInsights(backend.state!);
  const week = backend.cloud?.week_micro_usd;
  const pace = week && /^\d+$/.test(week) ? money(((BigInt(week) * 365n) / 7n).toString(), 0) : '—';
  const visible = machines.filter(
    (machine) =>
      `${machine.name} ${machine.chip}`.toLowerCase().includes(query.toLowerCase()) &&
      (filter === 'all' ||
        (['running', 'online', 'serving'].includes(machine.status)
          ? filter === 'online'
          : filter === 'offline')),
  );
  return (
    <>
      <Header
        title="My Macs"
        description="Earnings and readiness across your fleet."
        action={
          <Button onClick={() => void backend.refresh()}>
            <RotateCw size={14} /> Refresh
          </Button>
        }
      />
      <section className={styles.earnings} aria-label="Fleet earnings">
        <div className={styles.earningsMetrics}>
          <div>
            <span>Earned all time</span>
            <strong>{money(backend.cloud?.lifetime_micro_usd)}</strong>
          </div>
          <div>
            <span>Past 7 days</span>
            <b>{money(week)}</b>
          </div>
          <div>
            <span>Annualized pace</span>
            <b>
              {pace}
              <small>/yr</small>
            </b>
          </div>
        </div>
        <div className={styles.chartHeading}>
          <span>Daily earnings · 7 calendar days</span>
          <button className="text-link" onClick={onEarnings}>
            View earnings <ArrowUpRight size={13} />
          </button>
        </div>
        {data ? (
          <EarningsTimeline days={data.days} metric="earnings" />
        ) : (
          <p className={styles.emptyChart}>
            {backend.state!.linked
              ? error || 'Loading earnings history…'
              : 'Link this Mac to view earnings history.'}
          </p>
        )}
        {data && error && (
          <p role="status" className={styles.caption}>
            {error} Showing the last observation.
          </p>
        )}
        <p className={styles.caption}>
          Annualized from the past 7 days. A pace, not guaranteed income.
        </p>
      </section>
      <div className={styles.tableHeading}>
        <h2>Your Macs</h2>
        <span>{machines.length} Macs</span>
      </div>
      <div className={styles.filters}>
        <label className="search">
          <Search size={15} />
          <input
            aria-label="Search Macs"
            placeholder="Search name or chip"
            value={query}
            onChange={(event) => setQuery(event.target.value)}
          />
        </label>
        <select
          aria-label="Filter Macs"
          value={filter}
          onChange={(event) => setFilter(event.target.value)}
        >
          <option value="all">All Macs</option>
          <option value="online">Online</option>
          <option value="offline">Not online</option>
        </select>
      </div>
      <div className={styles.table}>
        <div className={styles.tableLabels}>
          <span>Mac</span>
          <span>Status</span>
          <span>Models</span>
          <span>Usage earnings · 7d</span>
        </div>
        {visible.map((machine) => {
          const Icon = machine.name.includes('Book') ? Laptop : Monitor;
          return (
            <button
              key={machine.id}
              className={styles.tableRow}
              aria-label={`Open ${machine.name}`}
              onClick={() => select(machine.id)}
            >
              <span className={styles.machineName}>
                <Icon size={22} />
                <span>
                  <strong>{machine.name}</strong>
                  <small>
                    {machine.id === backend.state!.machine.id ? 'This Mac' : 'View only'}
                  </small>
                  <small>
                    {machine.chip} ·{' '}
                    {machine.memory_gb ? `${machine.memory_gb} GB` : 'Memory unknown'}
                  </small>
                </span>
              </span>
              <Status
                state={
                  ['running', 'online', 'serving'].includes(machine.status) ? 'online' : 'offline'
                }
              >
                {machine.status}
              </Status>
              <span>{machine.models.length}</span>
              <strong>{money(machine.earnings_micro_usd)}</strong>
            </button>
          );
        })}
      </div>
      {!visible.length && <Empty title="No matching Macs">Try another name or filter.</Empty>}
      {!backend.cloud?.linked && (
        <p className={styles.caption}>
          Link each Mac to the same account to see its status and earnings here.
        </p>
      )}
    </>
  );
}
