import type { CSSProperties } from 'react';

export type GridState = 'idle' | 'scanning' | 'joined';

const columns = 7;
const cells = 42;
// The unlit cell this Mac takes when it joins the grid.
const own = { column: 3, row: 2 };

export function OnboardingIntro({ grid }: { grid: GridState }) {
  return (
    <div className="onboarding-intro">
      <span className="blue-label">Your Mac has more to give.</span>
      <h1>
        Be part
        <br />
        of the grid.
      </h1>
      <p>
        Run powerful models on your Mac.
        <br />
        Put idle compute to work on your terms.
      </p>
      <div className={`onboarding-grid ${grid}`} aria-hidden="true">
        {Array.from({ length: cells }, (_, i) => {
          const column = i % columns;
          const row = Math.floor(i / columns);
          const distance = Math.max(Math.abs(column - own.column), Math.abs(row - own.row));
          return (
            <i
              className={i % 5 === 0 || i % 7 === 0 ? 'lit' : distance ? undefined : 'own'}
              style={{ '--column': column, '--distance': distance } as CSSProperties}
              key={i}
            />
          );
        })}
      </div>
    </div>
  );
}
