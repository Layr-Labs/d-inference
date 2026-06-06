// Reputation/score as a 5-pip rating. Fill rounds score*5; color escalates
// down (green → amber → red) as the score drops, mirroring how the coordinator
// weights reputation in routing.

export function RatingPips({ score }: { score: number }) {
  const s = Math.max(0, Math.min(1, Number.isFinite(score) ? score : 0));
  const filled = Math.round(s * 5);
  const color = s < 0.3 ? "bg-accent-red" : s < 0.6 ? "bg-accent-amber" : "bg-accent-green";
  return (
    <div
      className="flex items-center gap-0.5"
      role="meter"
      aria-valuenow={Number(s.toFixed(2))}
      aria-valuemin={0}
      aria-valuemax={1}
      aria-label={`Reputation score ${s.toFixed(2)} of 1`}
    >
      {Array.from({ length: 5 }).map((_, i) => (
        <span
          key={i}
          className={`h-1.5 w-3 rounded-sm ${i < filled ? color : "bg-bg-tertiary"}`}
        />
      ))}
    </div>
  );
}
