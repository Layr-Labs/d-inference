import type { MacKind } from "@/lib/mac-hardware";

/** Distinct silhouettes, paired with a visible machine name by the caller. */
export function MacIcon({ kind, className }: { kind: MacKind; className?: string }) {
  return (
    <svg viewBox="0 0 64 48" fill="none" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" strokeLinejoin="round" className={className} aria-hidden="true">
      <MacShape kind={kind} />
    </svg>
  );
}

function MacShape({ kind }: { kind: MacKind }) {
  switch (kind) {
    case "studio": return (
        <>
          <path d="M10 17c0-4 3-6 7-6h30c4 0 7 2 7 6v20c0 3-3 5-7 5H17c-4 0-7-2-7-5Z" fill="currentColor" fillOpacity=".14" />
          <path d="M10 17c0 3 3 5 7 5h30c4 0 7-2 7-5M17 33h4m5 0h4m9 0h6" />
          <path d="M24 15h16" opacity=".35" />
          <circle cx="48" cy="37" r="1" fill="currentColor" stroke="none" />
          <path d="M17 44h30" opacity=".25" />
        </>
    );
    case "mini": return (
        <>
          <path d="M13 25c0-3 3-5 7-5h24c4 0 7 2 7 5v10c0 3-3 5-7 5H20c-4 0-7-2-7-5Z" fill="currentColor" fillOpacity=".14" />
          <path d="M13 25c0 3 3 5 7 5h24c4 0 7-2 7-5M21 35h4m6 0h4" />
          <path d="M26 24h12" opacity=".35" />
          <circle cx="44" cy="35" r="1" fill="currentColor" stroke="none" />
          <path d="M20 42h24" opacity=".25" />
        </>
    );
    case "macbook": return (
        <>
          <rect x="11" y="7" width="42" height="28" rx="3" fill="currentColor" fillOpacity=".12" />
          <path d="M15 31V11h34v20ZM5 40l6-5h42l6 5c-1 2-3 3-6 3H11c-3 0-5-1-6-3Z" />
          <path d="M26 36h12l2 3H24Z" fill="currentColor" fillOpacity=".15" />
          <path d="M29 10h6M21 26l7-7 6 5 8-9" opacity=".4" />
        </>
    );
    case "desktop": return (
        <>
          <rect x="8" y="5" width="48" height="31" rx="3" fill="currentColor" fillOpacity=".12" />
          <path d="M8 30h48M28 36l-2 7h12l-2-7" />
        </>
    );
    default: return (
        <>
          <rect x="17" y="8" width="30" height="32" rx="5" fill="currentColor" fillOpacity=".12" />
          <rect x="25" y="17" width="14" height="14" rx="2" />
          <path d="M29 13v4m6-4v4m-6 14v4m6-4v4M21 21h4m-4 6h4m14-6h4m-4 6h4" />
        </>
    );
  }
}
