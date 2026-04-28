"use client";

export function Logo({
  variant = "full",
  className = "",
}: {
  variant?: "full" | "compact";
  className?: string;
}) {
  if (variant === "compact") {
    return (
      <span className={`text-sm font-bold text-text-primary tracking-tight ${className}`} style={{ fontFamily: "'Louize', Georgia, serif" }}>
        D
      </span>
    );
  }

  return (
    <div className={className}>
      <h1 className="text-lg text-text-primary tracking-tight" style={{ fontFamily: "'Louize', Georgia, serif" }}>
        Darkbloom
      </h1>
      <p className="text-[10px] font-mono text-text-tertiary tracking-wide mt-0.5">
        An Eigen Labs project
      </p>
    </div>
  );
}
