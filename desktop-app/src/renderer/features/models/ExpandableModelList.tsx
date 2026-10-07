import { useId, useState, type ReactNode } from 'react';
import { ChevronDown } from 'lucide-react';
import styles from './expandableModels.module.css';

export function ExpandableModelList<T>({
  items,
  children,
}: {
  items: T[];
  children: (item: T) => ReactNode;
}) {
  const [expanded, setExpanded] = useState(false);
  const listId = useId();
  const extra = Math.max(0, items.length - 3);
  return (
    <>
      <div className="model-list" id={listId}>
        {(expanded ? items : items.slice(0, 3)).map(children)}
      </div>
      {extra > 0 && (
        <button
          className={styles.bar}
          aria-expanded={expanded}
          aria-controls={listId}
          onClick={() => setExpanded(!expanded)}
        >
          {expanded ? 'Show fewer models' : `Show ${extra} more models`}
          <ChevronDown size={16} />
        </button>
      )}
    </>
  );
}
