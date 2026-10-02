import type { BackendState } from '../useBackend';
export function ActivityChart({ backend }: { backend: BackendState }) {
  const samples = backend.state?.activity.samples || [];
  const deltas = samples.slice(1).map((s, i) => Math.max(0, s.requests - samples[i].requests));
  const max = Math.max(1, ...deltas);
  return (
    <div className="activity-chart" aria-label="Requests per observed interval">
      {deltas.length ? (
        deltas.map((n, i) => (
          <div className="activity-column" key={i} title={`${n} requests`}>
            <span style={{ height: `${Math.max(3, (n / max) * 100)}%` }} />
          </div>
        ))
      ) : (
        <p>Activity will appear as this Mac serves requests.</p>
      )}
    </div>
  );
}
