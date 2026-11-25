export type ContributionMode = 'network' | 'local';

const modes: { id: ContributionMode; title: string; description: string }[] = [
  {
    id: 'network',
    title: 'Contribute to Darkbloom',
    description: 'Make this Mac available and earn from its work.',
  },
  {
    id: 'local',
    title: 'Use models locally',
    description: 'Run your own apps with a local inference endpoint.',
  },
];

export function ModeChoice({
  mode,
  onChange,
}: {
  mode: ContributionMode;
  onChange: (mode: ContributionMode) => void;
}) {
  return (
    <div className="setup-modes" role="radiogroup" aria-label="How this Mac will be used">
      {modes.map((item) => (
        <label className={`choice ${mode === item.id ? 'selected' : ''}`} key={item.id}>
          <input
            type="radio"
            name="contribution-mode"
            checked={mode === item.id}
            onChange={() => onChange(item.id)}
          />
          <span>
            <strong>{item.title}</strong>
            <small>{item.description}</small>
          </span>
        </label>
      ))}
    </div>
  );
}
