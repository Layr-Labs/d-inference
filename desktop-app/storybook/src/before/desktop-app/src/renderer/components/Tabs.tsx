import { useRef, type HTMLAttributes, type KeyboardEvent } from 'react';
import styles from './tabs.module.css';

const tabIDs = (base: string, tab: string) => ({
  tab: `${base}-${tab}-tab`,
  panel: `${base}-${tab}-panel`,
});

export function TabPanel({
  base,
  tab,
  ...props
}: { base: string; tab: string } & HTMLAttributes<HTMLDivElement>) {
  const ids = tabIDs(base, tab);
  return <div {...props} role="tabpanel" id={ids.panel} aria-labelledby={ids.tab} />;
}

export function Tabs<T extends string>({
  base,
  label,
  tabs,
  selected,
  onSelect,
}: {
  base: string;
  label: string;
  tabs: readonly { id: T; label: string }[];
  selected: T;
  onSelect: (id: T) => void;
}) {
  const list = useRef<HTMLDivElement>(null);
  const keydown = (event: KeyboardEvent, index: number) => {
    const target: Record<string, number> = {
      ArrowRight: index + 1,
      ArrowLeft: index - 1,
      Home: 0,
      End: tabs.length - 1,
    };
    if (target[event.key] === undefined) return;
    event.preventDefault();
    const next = (target[event.key] + tabs.length) % tabs.length;
    onSelect(tabs[next].id);
    list.current?.querySelectorAll<HTMLButtonElement>('[role="tab"]')[next]?.focus();
  };
  return (
    <div ref={list} role="tablist" aria-label={label} className={styles.tabs}>
      {tabs.map((tab, index) => {
        const ids = tabIDs(base, tab.id);
        return (
          <button
            key={tab.id}
            type="button"
            role="tab"
            id={ids.tab}
            aria-controls={ids.panel}
            aria-selected={selected === tab.id}
            tabIndex={selected === tab.id ? 0 : -1}
            onClick={() => onSelect(tab.id)}
            onKeyDown={(event) => keydown(event, index)}
          >
            {tab.label}
          </button>
        );
      })}
    </div>
  );
}
