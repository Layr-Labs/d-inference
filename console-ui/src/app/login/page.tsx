"use client";

import { useAuth } from "@/hooks/useAuth";
import { useRouter, useSearchParams } from "next/navigation";
import { useEffect, Suspense } from "react";

function LoginContent() {
  const { ready, authenticated, login } = useAuth();
  const router = useRouter();
  const searchParams = useSearchParams();

  useEffect(() => {
    if (ready && authenticated) {
      const next = searchParams.get("next") || "/";
      router.replace(next);
    }
  }, [ready, authenticated, router, searchParams]);

  return (
    <div className="min-h-screen flex items-center justify-center bg-bg-primary">
      <div
        className="absolute inset-0 opacity-30"
        style={{
          background:
            "radial-gradient(ellipse at 50% 30%, var(--accent-brand-dim) 0%, transparent 70%)",
        }}
      />

      <div className="relative z-10 text-center max-w-md mx-auto px-6">
        <div className="mb-8">
          <h1 className="text-4xl font-bold text-text-primary tracking-tight">
            Eigen<span className="font-normal text-text-secondary">Inference</span>
          </h1>
          <p className="mt-2 text-sm text-text-tertiary">
            An Eigen Labs Research Project
          </p>
        </div>

        <div className="inline-flex items-center gap-2 px-3 py-1.5 rounded-full bg-accent-amber/10 text-accent-amber text-xs font-medium mb-6">
          <span className="w-1.5 h-1.5 rounded-full bg-accent-amber animate-pulse" />
          Experimental Research Preview
        </div>

        <p className="text-text-secondary text-base mb-8 leading-relaxed">
          Private AI inference through hardware-attested Apple Silicon providers.
          Your prompts stay encrypted, your data stays yours.
        </p>

        <button
          onClick={login}
          disabled={!ready}
          className="inline-flex items-center justify-center gap-2 px-8 py-3 rounded-xl
                     bg-accent-brand text-white font-medium text-base
                     hover:bg-accent-brand-hover transition-colors
                     disabled:opacity-40 disabled:cursor-not-allowed
                     shadow-lg focus-ring"
        >
          {!ready ? "Loading..." : "Sign In"}
        </button>

        <p className="mt-6 text-xs text-text-tertiary">
          Sign in with email, wallet, or social account
        </p>

        <p className="mt-8 text-xs text-text-tertiary leading-relaxed max-w-sm mx-auto">
          This is an experimental research project by Eigen Labs.
          The service is provided as-is for research and evaluation purposes.
          Not intended for production workloads.
        </p>
      </div>
    </div>
  );
}

export default function LoginPage() {
  return (
    <Suspense>
      <LoginContent />
    </Suspense>
  );
}
