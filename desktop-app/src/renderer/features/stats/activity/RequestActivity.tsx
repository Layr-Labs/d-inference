import { useId, useMemo, useState } from 'react';
import { LockKeyhole, RotateCw } from 'lucide-react';
import type { NativeModel } from '../../../../shared/contracts';
import { isPreview } from '../../../useBackend';
import { clockTime, count } from '../../../format';
import { Button } from '../../../components/UI';
import { RequestFilters } from './RequestFilters';
import { RequestTable } from './RequestTable';
import { useRequestHistory } from './useRequestHistory';
import { filterRequests, requestModels, type RequestFilter } from './requests';
import styles from './activity.module.css';

const PAGE = 25;

export function RequestActivity({
  models,
  scope,
  revision,
}: {
  models: NativeModel[];
  scope?: string;
  revision?: string;
}) {
  const { history, loading, failed, refresh } = useRequestHistory(scope, revision);
  const [filter, setFilter] = useState<RequestFilter>({ model: 'all', outcome: 'all' });
  const [shown, setShown] = useState(PAGE);
  const titleID = useId();
  const names = useMemo(
    () => new Map(models.map((model) => [model.id, model.display_name])),
    [models],
  );
  const change = (next: Partial<RequestFilter>) => {
    setFilter({ ...filter, ...next });
    setShown(PAGE);
  };
  const records = history ? filterRequests(history.records, filter) : [];
  return (
    <section className={styles.activity} aria-labelledby={titleID}>
      <div className={styles.heading}>
        <div>
          <h2 id={titleID}>Requests served</h2>
          <p>
            Recorded requests from this Mac
            {history?.since ? ` since ${clockTime(history.since, history.observed_at)}` : ''}.
          </p>
        </div>
        {history && (
          <Button disabled={loading} onClick={() => void refresh()}>
            <RotateCw size={14} /> Refresh
          </Button>
        )}
      </div>
      {isPreview && <p className={styles.preview}>Design preview · sample request history</p>}
      {!history ? (
        failed ? (
          <div className={styles.unavailable} role="status">
            <strong>Request history is unavailable</strong>
            <p>
              The Darkbloom runtime on this Mac didn’t return its request history. Runtimes that
              predate this view don’t report it yet.
            </p>
            <Button disabled={loading} onClick={() => void refresh()}>
              Try again
            </Button>
          </div>
        ) : (
          <p className={styles.empty}>Loading request history…</p>
        )
      ) : (
        <>
          {failed && (
            <p className={styles.notice} role="status">
              Couldn’t refresh request history. Showing the last observation.
            </p>
          )}
          <RequestFilters
            filter={filter}
            onChange={change}
            models={requestModels(history.records)}
            names={names}
            records={records}
          />
          {records.length ? (
            <RequestTable
              records={records.slice(0, shown)}
              names={names}
              now={history.observed_at}
            />
          ) : (
            <p className={styles.empty}>
              {history.records.length
                ? 'No requests match these filters.'
                : 'No requests yet. Requests this Mac serves will appear here.'}
            </p>
          )}
          {records.length > shown && (
            <div className={styles.more}>
              <Button onClick={() => setShown(shown + PAGE)}>Show more</Button>
              <span>
                Showing {shown} of {count(records.length)}
              </span>
            </div>
          )}
        </>
      )}
      <p className={styles.privacy}>
        <LockKeyhole size={13} />
        Only request metadata is kept: time, model, token counts, duration, outcome and earnings.
        Prompt and response content is never stored or shown.
      </p>
    </section>
  );
}
