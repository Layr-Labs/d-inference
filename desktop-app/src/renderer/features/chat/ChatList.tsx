import { useRef, useState, type KeyboardEvent } from 'react';
import { SquarePen, Trash2 } from 'lucide-react';
import { Button, Modal } from '../../components/UI';
import { PixelLoader } from './Indicators';
import type { Conversation } from './storage';
import { dateGroups } from './text';
import styles from './chat.module.css';

// Your chats by day, newest first: New chat on top, a row per chat, and Delete on each (asked
// first). Up and down arrows move between chats; Delete asks to remove the focused one.
export function ChatList({
  id,
  conversations,
  current,
  answering,
  onSelect,
  onNew,
  onDelete,
}: {
  id: string;
  conversations: Conversation[];
  current: string | null;
  // Chats with an answer streaming now.
  answering: ReadonlySet<string>;
  onSelect: (conversation: string) => void;
  onNew: () => void;
  onDelete: (conversation: string) => void;
}) {
  const [confirming, setConfirming] = useState<Conversation>();
  const list = useRef<HTMLElement>(null);
  const newChat = useRef<HTMLButtonElement>(null);
  const rows = () => [
    ...(list.current?.querySelectorAll<HTMLButtonElement>('[data-chat-row]') ?? []),
  ];
  const keys = (event: KeyboardEvent<HTMLButtonElement>, conversation: Conversation) => {
    const all = rows();
    const index = all.indexOf(event.currentTarget);
    const target: Record<string, number> = {
      ArrowDown: index + 1,
      ArrowUp: index - 1,
      Home: 0,
      End: all.length - 1,
    };
    if (event.key in target) {
      event.preventDefault();
      all[Math.max(0, Math.min(all.length - 1, target[event.key]))]?.focus();
    } else if (event.key === 'Delete' || event.key === 'Backspace') {
      event.preventDefault();
      setConfirming(conversation);
    }
  };
  const remove = () => {
    if (!confirming) return;
    const all = rows();
    const index = all.findIndex((row) => row.dataset.chatRow === confirming.id);
    onDelete(confirming.id);
    setConfirming(undefined);
    // Focus goes to the next chat, else New chat, once the dialog has returned it.
    requestAnimationFrame(() => {
      const next = rows();
      (next[Math.min(index, next.length - 1)] ?? newChat.current)?.focus();
    });
  };
  return (
    <>
      <nav ref={list} id={id} className={styles.list} aria-label="Chats">
        <button ref={newChat} type="button" className={styles.newChat} onClick={onNew}>
          <SquarePen size={15} strokeWidth={1.55} aria-hidden="true" />
          New chat
        </button>
        {conversations.length === 0 && (
          <p className={styles.listEmpty}>Your chats stay on this Mac.</p>
        )}
        {dateGroups(conversations).map((group) => (
          <section key={group.title} aria-label={group.title}>
            <h2 className={styles.groupTitle}>{group.title}</h2>
            <ul className={styles.rows}>
              {group.items.map((conversation) => {
                const selected = conversation.id === current;
                const live = answering.has(conversation.id);
                return (
                  <li
                    key={conversation.id}
                    className={styles.row}
                    data-current={selected || undefined}
                  >
                    <button
                      type="button"
                      className={styles.rowButton}
                      data-chat-row={conversation.id}
                      aria-current={selected ? 'true' : undefined}
                      onClick={() => onSelect(conversation.id)}
                      onKeyDown={(event) => keys(event, conversation)}
                    >
                      <span className={styles.rowTitle}>{conversation.title}</span>
                      {live && (
                        <>
                          <PixelLoader size={10} />
                          <span className="sr-only">, answering</span>
                        </>
                      )}
                    </button>
                    <button
                      type="button"
                      className={styles.rowDelete}
                      aria-label={`Delete ${conversation.title}`}
                      onClick={() => setConfirming(conversation)}
                    >
                      <Trash2 size={14} strokeWidth={1.55} />
                    </button>
                  </li>
                );
              })}
            </ul>
          </section>
        ))}
      </nav>
      {confirming && (
        <Modal title="Delete this chat?" onClose={() => setConfirming(undefined)}>
          <p className={styles.confirmTitle}>{confirming.title}</p>
          <div className="dialog-actions">
            <Button onClick={() => setConfirming(undefined)}>Cancel</Button>
            <Button variant="danger" onClick={remove}>
              Delete
            </Button>
          </div>
        </Modal>
      )}
    </>
  );
}
