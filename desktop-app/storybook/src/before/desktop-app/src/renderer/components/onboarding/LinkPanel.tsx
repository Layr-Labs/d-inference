import { ArrowUpRight, LoaderCircle } from 'lucide-react';
import type { Snapshot } from '../../../shared/contracts';
import { api } from '../../useBackend';
import { Button } from '../UI';
import styles from './linkPanel.module.css';

// Shown while the device-code link runs; serving starts by itself once the account is linked.
export function LinkPanel({ link, cancel }: { link: Snapshot['link']; cancel: () => void }) {
  return (
    <section className={styles.link} aria-label="Link your account" aria-busy>
      <header>
        <span className={styles.linkStep}>1</span>
        <span>
          <strong>Link your Darkbloom account</strong>
          <small>Serving starts as soon as you approve this Mac in your browser.</small>
        </span>
      </header>
      {link ? (
        <div className={styles.code}>
          <strong aria-label={`Link code ${link.code}`}>{link.code}</strong>
          <Button variant="primary" onClick={() => void api?.openExternal('link')}>
            Open browser <ArrowUpRight size={15} />
          </Button>
        </div>
      ) : (
        <div className={styles.code}>
          <i className={styles.codePlaceholder} />
        </div>
      )}
      <footer>
        <span role="status">
          <LoaderCircle className="spin" size={13} />
          {link ? 'Waiting for approval…' : 'Getting a link code…'}
        </span>
        <button className="text-link" onClick={cancel}>
          Cancel
        </button>
      </footer>
    </section>
  );
}
