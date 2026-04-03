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
      <span className={`text-sm font-bold text-text-primary tracking-tight ${className}`}>
        E<span className="font-normal text-text-secondary">I</span>
      </span>
    );
  }

  return (
    <div className={className}>
      <h1 className="text-lg font-bold text-text-primary tracking-tight">
        Eigen<span className="font-normal text-text-secondary">Inference</span>
      </h1>
      <p className="text-xs text-text-tertiary mt-0.5">
        An Eigen Labs Research Project
      </p>
    </div>
  );
}
