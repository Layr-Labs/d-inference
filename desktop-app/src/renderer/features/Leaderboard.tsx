import type { BackendState } from '../useBackend';
import { compact } from '../format';
import { Empty, Header } from '../components/UI';

export function Leaderboard({ backend }: { backend: BackendState }) {
  return (
    <>
      <Header title="Leaderboard" description="The people keeping the grid moving." />
      <div className="leaderboard-head">
        <span>Provider</span>
        <span>Tokens generated</span>
      </div>
      {backend.leaders.length ? (
        backend.leaders.map((leader, i) => (
          <div className="leader-row" key={leader.rank || i}>
            <span className="rank">{String(i + 1).padStart(2, '0')}</span>
            <span className="leader-avatar">{leader.name?.charAt(0).toUpperCase() || 'D'}</span>
            <strong>{leader.name || 'Provider'}</strong>
            <span>{compact(leader.tokens)}</span>
          </div>
        ))
      ) : (
        <Empty title="Leaderboard unavailable">
          The network leaderboard will appear when the service is available.
        </Empty>
      )}
      <div className="leader-footer">Every Mac contributes to the grid.</div>
    </>
  );
}
