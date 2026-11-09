import { CornerDownLeft } from 'lucide-react';
import { useEffect, useId, useRef, useState, type KeyboardEvent, type RefObject } from 'react';
import type { ClusterQuestion, ClusterSessionAnswer } from '../../../shared/cluster';
import { Button } from '../../components/UI';
import { Said } from './Rich';
import { option, type Prompt } from './transcript';
import styles from './cluster.module.css';

type Choose = Extract<ClusterQuestion, { type: 'choose' }>;
type Key = Extract<ClusterQuestion, { type: 'key' }>;

// Focus moves to a new question unless the person is somewhere else on purpose (a dialog, a
// field), the way the terminal's list takes the keys as soon as it shows.
const mayTakeFocus = (within: HTMLElement | null) => {
  const active = document.activeElement;
  return (
    !active ||
    active === document.body ||
    (!!within && within.contains(active) && !active.closest('[role="dialog"]'))
  );
};

type Within = RefObject<HTMLElement | null>;

// One of the options, as the terminal's arrow-key list: ↑↓ (and ←→) move, Enter takes, the
// default starts selected. Each option is a real button: its first row is its title, the rest
// its detail, and the split and state the CLI marks show as small tags.
export function ChoiceList({
  question,
  label,
  disabled,
  within,
  onChoose,
}: {
  question: Choose;
  label: string;
  disabled: boolean;
  within: Within;
  onChoose: (choice: number) => void;
}) {
  const options = question.options.map(option);
  const count = options.length;
  const initial = Math.min(Math.max(0, question.selected), Math.max(0, count - 1));
  const [active, setActive] = useState(initial);
  const buttons = useRef<(HTMLButtonElement | null)[]>([]);
  const base = useId();
  const compact =
    count <= 3 &&
    options.every(
      (item) =>
        item.title.length <= 24 &&
        !item.details.length &&
        !item.modes.length &&
        !item.facts.length &&
        !item.warnings.length,
    );
  useEffect(() => {
    setActive(initial);
    if (mayTakeFocus(within.current)) buttons.current[initial]?.focus();
    // A new question (its id) starts again at its default.
  }, [question.id]);
  const move = (to: number) => {
    const next = (to + count) % count;
    setActive(next);
    buttons.current[next]?.focus();
  };
  const keydown = (event: KeyboardEvent, index: number) => {
    // Enter takes the option, as in Terminal; handled here so the button's own click can't
    // answer twice.
    if (event.key === 'Enter') {
      event.preventDefault();
      if (!disabled) onChoose(index);
      return;
    }
    const target: Record<string, number> = {
      ArrowDown: index + 1,
      ArrowRight: index + 1,
      ArrowUp: index - 1,
      ArrowLeft: index - 1,
      Home: 0,
      End: count - 1,
    };
    if (target[event.key] === undefined) return;
    event.preventDefault();
    move(target[event.key]);
  };
  return (
    <div className={styles.choiceBlock}>
      <ul className={compact ? styles.choicesInline : styles.choices} aria-label={label}>
        {options.map((item, index) => {
          const detail = `${base}-${index}`;
          const described = item.details.length > 0 || item.facts.length > 0;
          return (
            <li key={index}>
              <button
                ref={(element) => {
                  buttons.current[index] = element;
                }}
                type="button"
                className={styles.choice}
                data-active={index === active || undefined}
                data-default={index === question.selected || undefined}
                tabIndex={index === active ? 0 : -1}
                disabled={disabled}
                aria-describedby={described ? detail : undefined}
                onFocus={() => setActive(index)}
                onKeyDown={(event) => keydown(event, index)}
                onClick={() => onChoose(index)}
              >
                <span className={styles.choiceTitle}>
                  <span>{item.title}</span>
                  {item.modes.map((mode) => (
                    <span key={mode} className={styles.tagMode}>
                      {mode}
                    </span>
                  ))}
                  {item.marks.map((mark) => (
                    <span key={mark} className={styles.tagMark}>
                      {mark}
                    </span>
                  ))}
                  {item.warnings.map((warning) => (
                    <span key={warning} className={styles.tagWarning}>
                      {warning}
                    </span>
                  ))}
                </span>
                {described && (
                  <span id={detail} className={styles.choiceDetail}>
                    {item.facts.length > 0 && (
                      <span className={styles.choiceFacts}>{item.facts.join(' · ')}</span>
                    )}
                    {item.details.map((row, position) => (
                      <span key={position}>{row}</span>
                    ))}
                  </span>
                )}
                {!compact && (
                  <span className={styles.choiceEnter} aria-hidden="true">
                    <CornerDownLeft size={13} />
                  </span>
                )}
              </button>
            </li>
          );
        })}
      </ul>
      {count > 1 && (
        <p className={styles.keysHint} aria-hidden="true">
          {compact ? '←→ to move · Enter to choose' : '↑↓ to move · Enter to choose'}
        </p>
      )}
    </div>
  );
}

// What the setup accepts while it works, one button per key.
export function KeyButtons({
  question,
  disabled,
  onKey,
}: {
  question: Key;
  disabled: boolean;
  onKey: (key: string) => void;
}) {
  if (!question.keys.length) return null;
  return (
    <div className={styles.keyButtons}>
      {question.keys.map((item) => (
        <Button key={item.key} disabled={disabled} onClick={() => onKey(item.key)}>
          {item.label}
        </Button>
      ))}
    </div>
  );
}

// The pairing code, large enough to compare across the room with the other Mac's screen.
export function PairingCode({ code }: { code: string }) {
  return (
    <div className={styles.pairingCode}>
      <span>Pairing code</span>
      <strong aria-label={`Pairing code ${code.replace(/\s/g, '')}`}>
        {code.split(' ').map((group, index) => (
          <span key={index}>{group}</span>
        ))}
      </strong>
    </div>
  );
}

// The open question: its own lines (and a pairing code), then its options or keys.
export function QuestionCard({
  question,
  prompt,
  fallback,
  disabled,
  within,
  onAnswer,
}: {
  question: ClusterQuestion;
  prompt: Prompt | null;
  // What the question is about when no line asks it (the step's title, such as Model).
  fallback: string;
  disabled: boolean;
  within: Within;
  onAnswer: (answer: ClusterSessionAnswer) => void;
}) {
  const heading = useId();
  const [ask, ...more] = prompt?.lines ?? [];
  return (
    <section
      className={styles.question}
      data-code={prompt?.code ? true : undefined}
      aria-labelledby={ask ? heading : undefined}
      aria-label={ask ? undefined : fallback}
    >
      {prompt?.code && <PairingCode code={prompt.code} />}
      {ask && (
        <h3 id={heading} className={styles.questionTitle}>
          <Said text={ask.text} stressed={ask.stressed} />
        </h3>
      )}
      {more.map((line) => (
        <p key={line.key} className={styles.questionNote}>
          <Said text={line.text} stressed={line.stressed} />
        </p>
      ))}
      {question.type === 'choose' ? (
        <ChoiceList
          question={question}
          label={ask?.text ?? fallback}
          disabled={disabled}
          within={within}
          onChoose={(choice) => onAnswer({ question: question.id, choice })}
        />
      ) : (
        <KeyButtons
          question={question}
          disabled={disabled}
          onKey={(key) => onAnswer({ question: question.id, key })}
        />
      )}
    </section>
  );
}
