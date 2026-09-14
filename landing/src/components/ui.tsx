import type { ReactNode } from "react";

export function Arrow({ diagonal = false }: { diagonal?: boolean }) {
  return (
    <svg
      width="18"
      height="18"
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth="1.5"
      aria-hidden="true"
    >
      <path d={diagonal ? "M6 18 18 6M6 6h12v12" : "M4 12h16m-6-6 6 6-6 6"} />
    </svg>
  );
}

export function Mark({ className = "" }: { className?: string }) {
  return (
    <svg
      className={className}
      width="26"
      height="30"
      viewBox="0 0 221 253"
      fill="currentColor"
      aria-hidden="true"
    >
      <path d="M126.46 126.46H94.85V189.67H63.22V0H0V252.91H189.69V189.67H126.46Z" />
      <path d="M221.31 0H189.7V63.22H221.31Z" />
      <path d="M158.08 0H96.13V31.62H126.46V126.44H189.69V63.2H158.08Z" />
    </svg>
  );
}

export function SectionLabel({ children }: { children: ReactNode }) {
  return (
    <p className="eyebrow">
      <span className="label-dot" />
      {children}
    </p>
  );
}

export function FeatureIcon({ type }: { type: "lock" | "chip" | "code" }) {
  return (
    <svg
      width="27"
      height="27"
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth="1.3"
      aria-hidden="true"
    >
      {type === "lock" && (
        <>
          <rect x="5" y="10" width="14" height="11" rx="2" />
          <path d="M8 10V6a4 4 0 0 1 8 0v4m-4 4v3" />
        </>
      )}
      {type === "chip" && (
        <>
          <rect x="5" y="5" width="14" height="14" rx="2" />
          <path d="M9 9h6v6H9zM9 2v3m6-3v3M9 19v3m6-3v3M2 9h3m-3 6h3m14-6h3m-3 6h3" />
        </>
      )}
      {type === "code" && <path d="m7 6-6 6 6 6m10-12 6 6-6 6M14 3l-4 18" />}
    </svg>
  );
}
