// Concurrency as a row of dots — one per slot, filled up to the number of
// in-flight requests. Caps the rendered dots so a huge max_concurrency doesn't
// blow out the layout; the mono "pending/max" number carries the exact figure.

const MAX_DOTS = 16;

export function ConcurrencyDots({
  pending,
  max,
}: {
  pending: number;
  max: number;
}) {
  const total = Math.max(0, max || 0);
  const filled = Math.max(0, Math.min(pending || 0, total));
  const dots = Math.min(total, MAX_DOTS);
  const overflow = total > MAX_DOTS;

  if (total === 0) {
    return <span className="text-[11px] text-text-tertiary">—</span>;
  }

  // When capped, scale the filled count into the rendered dot range.
  const renderedFilled = overflow ? Math.round((filled / total) * dots) : filled;

  return (
    <div
      className="flex items-center gap-1"
      role="meter"
      aria-valuenow={filled}
      aria-valuemin={0}
      aria-valuemax={total}
      aria-label={`Concurrency: ${filled} of ${total}`}
    >
      <div className="flex items-center gap-0.5">
        {Array.from({ length: dots }).map((_, i) => (
          <span
            key={i}
            className={`w-1.5 h-1.5 rounded-full ${
              i < renderedFilled ? "bg-accent-brand" : "bg-bg-tertiary"
            }`}
          />
        ))}
        {overflow && <span className="text-[10px] text-text-tertiary ml-0.5">+</span>}
      </div>
    </div>
  );
}
