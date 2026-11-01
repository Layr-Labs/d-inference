import { ArrowUpRight, Check, Copy, LoaderCircle } from 'lucide-react';
import { useState } from 'react';
import type { Snapshot } from '../../../shared/contracts';
import { api } from '../../useBackend';
import { Button } from '../UI';
import styles from './linkPanel.module.css';

// Shown while the device-code link runs; setup moves on by itself once the account is linked.
// The browser opens only from the button.
export function LinkPanel({ link, cancel }: { link: Snapshot['link']; cancel: () => void }) {
  // The code is typed on another page; copying it avoids misreading or mistyping it.
  const [copied, setCopied] = useState('');
  async function copy(code: string) {
    try {
      await api?.copy(code);
      setCopied(code);
    } catch {
      setCopied('');
    }
  }
  return (
    <section className={styles.link} aria-label="Link your account" aria-busy>
      <header>
        <span className={styles.linkStep}>1</span>
        <span>
          <strong>Link your Darkbloom account</strong>
          <small>Open the link page and enter this code. Then approve this Mac.</small>
        </span>
      </header>
      {link ? (
        <div className={styles.code}>
          <span className={styles.codeValue}>
            <strong aria-label={`Link code ${link.code}`}>{link.code}</strong>
            <Button onClick={() => void copy(link.code)}>
              {copied === link.code ? <Check size={15} /> : <Copy size={15} />}
              {copied === link.code ? 'Copied' : 'Copy code'}
            </Button>
          </span>
          <Button variant="primary" onClick={() => void api?.openExternal('link')}>
            Open link page <ArrowUpRight size={15} />
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
        <Button onClick={cancel}>Cancel</Button>
      </footer>
    </section>
  );
}
