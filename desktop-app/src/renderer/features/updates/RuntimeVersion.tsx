import { ArrowRight, Check, Download, ShieldAlert } from 'lucide-react';
import type { BackendState } from '../../useBackend';
import { Button, Notice } from '../../components/UI';
import { publishedVersions, releaseStatus, runtimeVersion, updateAvailable } from './version';
import styles from './updates.module.css';

export function RuntimeVersion({ backend }: { backend: BackendState }) {
  const installed = runtimeVersion(backend.state!);
  const { latest, minimum } = publishedVersions(backend);
  const retired = backend.releaseHistory?.history?.some(
    (release) => release.version === installed && !release.active,
  );
  const status = releaseStatus(installed, latest, minimum, retired);
  const canUpdate = updateAvailable(installed, latest, minimum);
  return (
    <section className={styles.versionPanel}>
      <div className={styles.stateLine} data-status={status}>
        {status === 'required' || status === 'retired' ? (
          <ShieldAlert size={19} />
        ) : status === 'current' ? (
          <Check size={19} />
        ) : (
          <Download size={19} />
        )}
        <strong>
          {status === 'required'
            ? 'Update required'
            : status === 'retired'
              ? 'This release is retired'
              : status === 'available'
                ? 'Update available'
                : status === 'current'
                  ? 'You’re up to date'
                  : backend.release?.error
                    ? 'Release status unavailable'
                    : 'Checking release status'}
        </strong>
      </div>
      <div className={styles.versions}>
        <div>
          <span>This Mac’s runtime</span>
          <strong>{installed}</strong>
        </div>
        <ArrowRight size={23} />
        <div>
          <span>Latest release</span>
          <strong>{latest || '—'}</strong>
        </div>
        {(status === 'required' || status === 'available' || status === 'retired') && (
          <Button
            variant="primary"
            disabled={backend.busy || !canUpdate}
            onClick={() => void backend.act({ action: 'update' })}
          >
            <Download size={15} /> Update now
          </Button>
        )}
      </div>
      {status === 'required' && (
        <p className={styles.required}>This version can no longer receive network requests.</p>
      )}
      {(status === 'required' || status === 'retired') && !canUpdate && (
        <p className={styles.muted}>
          A compatible update isn’t available yet. Check again shortly.
        </p>
      )}
      <div className={styles.support}>
        {minimum ? (
          <>
            <span>
              Minimum <b>{minimum}+</b>
            </span>
            <span>
              Cut off <b>before {minimum}</b>
            </span>
          </>
        ) : (
          <span>{minimum === '' ? 'No minimum version cutoff' : 'Support policy unavailable'}</span>
        )}
      </div>
      {backend.release?.error && <Notice>{backend.release.error}</Notice>}
    </section>
  );
}
