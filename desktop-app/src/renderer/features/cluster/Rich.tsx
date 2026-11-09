import { Check, Copy } from 'lucide-react';
import { useEffect, useState } from 'react';
import { api } from '../../useBackend';
import styles from './cluster.module.css';

// The CLI's sentences as they are, with each `command` in <code>.
export function Rich({ text }: { text: string }) {
  const parts = text.split(/(`[^`\n]+`)/g);
  return (
    <>
      {parts.map((part, index) =>
        part.length > 2 && part.startsWith('`') && part.endsWith('`') ? (
          <code key={index}>{part.slice(1, -1)}</code>
        ) : (
          part
        ),
      )}
    </>
  );
}

// A line with the part a terminal shows in bold.
export function Said({
  text,
  stressed,
}: {
  text: string;
  stressed?: { lead: string; stressed: string; tail: string };
}) {
  if (!stressed) return <Rich text={text} />;
  return (
    <>
      <Rich text={stressed.lead} />
      <strong>
        <Rich text={stressed.stressed} />
      </strong>
      <Rich text={stressed.tail} />
    </>
  );
}

// One command to run in Terminal, with Copy. `bare`: the Copy button alone, beside a sentence that
// already shows the command.
export function CopyCommand({
  command,
  label,
  bare,
}: {
  command: string;
  label?: string;
  bare?: boolean;
}) {
  const [copied, setCopied] = useState(false);
  useEffect(() => {
    if (!copied) return;
    const timer = setTimeout(() => setCopied(false), 1600);
    return () => clearTimeout(timer);
  }, [copied]);
  return (
    <span className={bare ? styles.commandBare : styles.command}>
      {label && <span className={styles.commandLabel}>{label}</span>}
      {!bare && <code>{command}</code>}
      <button
        type="button"
        className={styles.copy}
        aria-label={copied ? `Copied ${command}` : `Copy ${command}`}
        title={copied ? 'Copied' : 'Copy'}
        onClick={() =>
          void api
            ?.copy(command)
            .then(() => setCopied(true))
            .catch(() => setCopied(false))
        }
      >
        {copied ? <Check size={13} /> : <Copy size={13} />}
      </button>
    </span>
  );
}
