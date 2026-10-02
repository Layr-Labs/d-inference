import { ChevronDown } from 'lucide-react';
import type { ReleaseData, ReleaseHistory } from '../../../shared/contracts';
import { compareVersions } from './version';
import styles from './updates.module.css';

function lines(notes: string) {
  return notes
    .split('\n')
    .map((line) =>
      line
        .replace(/^\s*(?:#{1,6}|[-*+]|\d+\.)\s+/, '')
        .replace(/\*\*/g, '')
        .trim(),
    )
    .filter(Boolean);
}
export function ReleaseTimeline({
  history,
  latest,
  installed,
}: {
  history?: ReleaseHistory;
  latest?: ReleaseData;
  installed: string;
}) {
  const releases = history?.history?.length
    ? history.history
    : latest?.version
      ? [
          {
            version: latest.version,
            notes: latest.notes || '',
            published_at: latest.published_at || '',
            active: true,
          },
        ]
      : [];
  return (
    <section className={styles.timelineSection}>
      <div className={styles.sectionHead}>
        <h2>What’s new</h2>
        <span>Release history</span>
      </div>
      {history?.error && (
        <p className={styles.muted}>
          History unavailable{latest?.version ? ' · showing the latest release' : ''}
        </p>
      )}
      {releases.length ? (
        <ol className={styles.timeline}>
          {releases.map((release) => {
            const notes = lines(release.notes);
            const retired =
              !release.active ||
              (history?.minimum_provider_version &&
                compareVersions(release.version, history.minimum_provider_version) === -1);
            return (
              <li key={release.version}>
                <div className={styles.releaseVersion}>
                  <strong>{release.version}</strong>
                  <time>
                    {Number.isFinite(Date.parse(release.published_at))
                      ? new Date(release.published_at).toLocaleDateString(undefined, {
                          month: 'short',
                          day: 'numeric',
                        })
                      : ''}
                  </time>
                </div>
                <div className={styles.releaseBody}>
                  <div className={styles.badges}>
                    {release.version === installed && <span>Installed</span>}
                    {retired && <span className={styles.retired}>Retired</span>}
                    {release.version === latest?.version && <span>Latest</span>}
                  </div>
                  {notes.length ? (
                    <>
                      <p className={styles.summary}>
                        {notes[0].length > 150 ? `${notes[0].slice(0, 147)}…` : notes[0]}
                      </p>
                      <details>
                        <summary>
                          Release notes <ChevronDown size={13} />
                        </summary>
                        <ul>
                          {notes.map((line, i) => (
                            <li key={i}>{line}</li>
                          ))}
                        </ul>
                      </details>
                    </>
                  ) : (
                    <p className={styles.muted}>Release notes haven’t been published yet.</p>
                  )}
                </div>
              </li>
            );
          })}
        </ol>
      ) : (
        <p className={styles.muted}>Release notes will appear when published.</p>
      )}
    </section>
  );
}
