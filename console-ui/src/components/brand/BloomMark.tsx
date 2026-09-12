/** The existing Darkbloom favicon, using the current theme's brand ink. */
export function BloomMark({ size = 28, className = "" }: { size?: number; className?: string }) {
  return (
    <svg width={size} height={size} viewBox="0 0 222 253" fill="currentColor" aria-hidden="true" className={className}>
      <path d="M126.46 126.46H94.85V189.67H63.22V126.44V0H0V252.91H63.22V252.89H94.85V252.91H126.46V252.89H189.69V189.67H126.46V126.46Z" />
      <path d="M221.31 0H189.7V63.22H221.31V0Z" />
      <path d="M158.08 0H126.46V0.01H96.13V31.62H126.46V126.44H158.08V126.43H189.69V63.2H158.08V0Z" />
    </svg>
  );
}
