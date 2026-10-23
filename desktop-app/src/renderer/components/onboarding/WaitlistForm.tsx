import { Check, LoaderCircle, Mail } from 'lucide-react';
import { useId, useState, type FormEvent } from 'react';
import { api } from '../../useBackend';
import { Button } from '../UI';
import { joinWaitlist, validEmail, waitlistError } from './waitlist';
import styles from './waitlist.module.css';

type Status =
  | { kind: 'editing' }
  | { kind: 'invalid' }
  | { kind: 'sending' }
  | { kind: 'joined'; email: string }
  | { kind: 'failed'; message: string };

export function WaitlistForm({ reasons }: { reasons: string[] }) {
  const messageID = useId();
  const [email, setEmail] = useState('');
  const [status, setStatus] = useState<Status>({ kind: 'editing' });
  async function submit(event: FormEvent) {
    event.preventDefault();
    const address = email.trim();
    if (!validEmail(address)) return setStatus({ kind: 'invalid' });
    setStatus({ kind: 'sending' });
    try {
      await joinWaitlist(api, address, reasons);
      setStatus({ kind: 'joined', email: address });
    } catch (error) {
      setStatus({ kind: 'failed', message: waitlistError(error) });
    }
  }
  if (status.kind === 'joined')
    return (
      <div className={styles.joined} role="status">
        <Check size={16} strokeWidth={2.2} />
        <p>
          <strong>You’re on the waitlist.</strong> We’ll email {status.email} as soon as Darkbloom
          can run on this Mac.
        </p>
      </div>
    );
  const message =
    status.kind === 'invalid'
      ? 'Enter a valid email address, like name@example.com.'
      : status.kind === 'failed'
        ? `We couldn’t add you to the waitlist. ${status.message}`
        : undefined;
  return (
    <form className={styles.waitlist} noValidate onSubmit={(event) => void submit(event)}>
      <h3>Get notified</h3>
      <p>We’ll email you as soon as Darkbloom can run on this Mac.</p>
      <div className={styles.field}>
        <input
          type="email"
          aria-label="Email address"
          placeholder="you@example.com"
          autoComplete="email"
          value={email}
          aria-invalid={status.kind === 'invalid'}
          aria-describedby={message ? messageID : undefined}
          onChange={(event) => {
            setEmail(event.target.value);
            if (status.kind === 'invalid') setStatus({ kind: 'editing' });
          }}
        />
        <Button variant="primary" type="submit" disabled={status.kind === 'sending'}>
          {status.kind === 'sending' ? (
            <LoaderCircle className="spin" size={15} />
          ) : (
            <Mail size={15} />
          )}
          {status.kind === 'failed' ? 'Try again' : 'Join the waitlist'}
        </Button>
      </div>
      {message && (
        <p id={messageID} className={styles.message} role="alert">
          {message}
        </p>
      )}
    </form>
  );
}
