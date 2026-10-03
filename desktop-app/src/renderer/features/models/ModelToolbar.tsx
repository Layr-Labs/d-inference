import { Search } from 'lucide-react';

export function ModelToolbar<Filter extends string>({
  filters,
  filter,
  onFilter,
  query,
  onQuery,
}: {
  filters: readonly { id: Filter; label: string }[];
  filter: Filter;
  onFilter: (filter: Filter) => void;
  query: string;
  onQuery: (query: string) => void;
}) {
  return (
    <div className="toolbar">
      <div className="segmented" aria-label="Filter models">
        {filters.map((item) => (
          <button
            className={filter === item.id ? 'selected' : ''}
            aria-pressed={filter === item.id}
            key={item.id}
            onClick={() => onFilter(item.id)}
          >
            {item.label}
          </button>
        ))}
      </div>
      <label className="search">
        <Search size={16} />
        <input
          value={query}
          onChange={(event) => onQuery(event.target.value)}
          placeholder="Search models"
          aria-label="Search models"
        />
      </label>
    </div>
  );
}

export const matchesQuery = (
  model: { display_name: string; id: string; family?: string },
  query: string,
) =>
  `${model.display_name} ${model.id} ${model.family}`.toLowerCase().includes(query.toLowerCase());
