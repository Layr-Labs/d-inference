"use client";

import { trackEvent } from "@/lib/google-analytics";
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
      <div className="relative z-10 text-center max-w-md mx-auto px-6">
        <h1 className="text-5xl text-ink mb-3" style={{ fontFamily: "'Louize', Georgia, serif", letterSpacing: "-0.03em" }}>
          Darkbloom
        </h1>
        <p className="text-base text-text-secondary mb-8 leading-relaxed">
          Private inference on verified hardware.
          <br />
          <span className="text-text-tertiary">Your prompts stay encrypted, your data stays yours.</span>
        </p>

        <button
          onClick={() => {
            trackEvent("login_cta_clicked", {
              location: "login_page",
            });
            login();
          }}
          disabled={!ready}
          className="inline-flex items-center justify-center gap-2 px-8 py-3 rounded-lg
                     bg-coral text-white font-bold text-sm
                     hover:opacity-90
                     disabled:opacity-40 disabled:cursor-not-allowed
                     transition-all focus-ring"
        >
          {!ready ? "Loading..." : "Sign In"}
        </button>

        <p className="mt-4 text-xs text-text-tertiary">
          Sign in with email, wallet, or social account
        </p>

        <p className="mt-12 text-xs font-mono text-text-tertiary tracking-wide">
          End-to-end encrypted · Apple Silicon · Decentralized
        </p>

        <p className="mt-4 text-[10px] text-text-tertiary leading-relaxed max-w-xs mx-auto">
          An Eigen Labs research project. Provided as-is for evaluation.
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
