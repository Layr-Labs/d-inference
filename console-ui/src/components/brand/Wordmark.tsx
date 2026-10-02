/** Canonical vector wordmark from landing/public/logo.svg. */
export function Wordmark() {
  // A plain image keeps the SVG lossless and avoids unnecessary image optimization.
  // eslint-disable-next-line @next/next/no-img-element
  return <img src="/brand/darkbloom.svg" alt="Darkbloom" width={1584} height={196} className="brand-wordmark" />;
}
