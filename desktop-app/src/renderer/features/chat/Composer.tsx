import { type ReactNode, type RefObject } from 'react';
import { ArrowUp, Square } from 'lucide-react';
import styles from './chat.module.css';

// The message field, from the iPhone app's composer: one rounded field, and send (or stop) on
// the same line. Enter sends; Shift+Enter starts a new line.
export function Composer({
  field,
  draft,
  onDraft,
  placeholder,
  disabled,
  answering,
  onSend,
  onStop,
  above,
}: {
  field: RefObject<HTMLTextAreaElement | null>;
  draft: string;
  onDraft: (draft: string) => void;
  placeholder: string;
  // No model to send to (the list is still loading).
  disabled: boolean;
  // The model is answering in this chat: Stop replaces Send until it finishes.
  answering: boolean;
  onSend: (text: string) => void;
  onStop: () => void;
  above?: ReactNode;
}) {
  const canSend = !disabled && !answering && draft.trim().length > 0;
  const send = () => {
    if (canSend) onSend(draft);
  };
  return (
    <div className={styles.composerInner}>
      {above}
      <form
        className={styles.composer}
        onSubmit={(event) => {
          event.preventDefault();
          send();
        }}
      >
        <textarea
          ref={field}
          className={styles.field}
          rows={1}
          value={draft}
          placeholder={placeholder}
          aria-label="Message"
          disabled={disabled}
          onChange={(event) => onDraft(event.target.value)}
          onKeyDown={(event) => {
            if (event.key !== 'Enter' || event.shiftKey || event.nativeEvent.isComposing) return;
            event.preventDefault();
            send();
          }}
        />
        {answering ? (
          <button
            key="stop"
            type="button"
            className={styles.stop}
            aria-label="Stop"
            onClick={onStop}
          >
            <Square size={13} strokeWidth={0} fill="currentColor" aria-hidden="true" />
          </button>
        ) : (
          <button
            key="send"
            type="submit"
            className={styles.send}
            aria-label="Send"
            disabled={!canSend}
          >
            <ArrowUp size={18} strokeWidth={2} aria-hidden="true" />
          </button>
        )}
      </form>
    </div>
  );
}
