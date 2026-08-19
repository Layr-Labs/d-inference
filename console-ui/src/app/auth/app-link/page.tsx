"use client";

import { trackEvent } from "@/lib/google-analytics";
import { useAuth } from "@/hooks/useAuth";
import { useEffect, useState, Suspense } from "react";

// Handoff target for the macOS app's ASWebAuthenticationSession.
export const APP_CALLBACK_URL = "darkbloom://auth/callback";

// The Privy JWT rides the URL *fragment* (`#token=`), not a query parameter.
// Fragments are never transmitted in HTTP requests, so the token cannot end
// up in console/edge server logs, Referer headers, or analytics beacons —
// it only exists inside the browser's own navigation. The app registers the
// `darkbloom` scheme, and ASWebAuthenticationSession hands the full URL
// (fragment included) to the app before any network fetch happens.
// `window.location.replace` additionally keeps the token-bearing URL out of
// the auth browser's back-stack (the app uses an ephemeral session anyway).
export function buildAppCallbackURL(token: string): string {
  return `${APP_CALLBACK_URL}#token=${encodeURIComponent(token)}`;
}

function AppLinkContent() {
  const { ready, authenticated, login, getAccessToken } = useAuth();
  // idle: waiting for Privy → handing off → handedOff | error.
  const [phase, setPhase] = useState<"idle" | "handingOff" | "handedOff" | "error">("idle");

  const handoff = async () => {
    if (phase === "handingOff") return;
    setPhase("handingOff");
    const token = await getAccessToken().catch(() => null);
    if (!token) {
      setPhase("error");
      return;
    }
    window.location.replace(buildAppCallbackURL(token));
    setPhase("handedOff");
  };

  // The app opens this page inside ASWebAuthenticationSession. Once the user
  // is authenticated (or already was via a non-ephemeral visit), hand the
  // session token to the app immediately — no extra click in the common case.
  useEffect(() => {
    if (ready && authenticated && phase === "idle") {
      void handoff();
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [ready, authenticated, phase]);

  const showHandedOff = phase === "handedOff";
  const showError = phase === "error";

  return (
    <div className="min-h-screen flex items-center justify-center bg-bg-primary">
      <div className="relative z-10 text-center max-w-md mx-auto px-6">
        <h1
          className="text-5xl text-ink mb-3"
          style={{ fontFamily: "'Louize', Georgia, serif", letterSpacing: "-0.03em" }}
        >
          Darkbloom
        </h1>

        {!authenticated && (
          <>
            <p className="text-base text-text-secondary mb-8 leading-relaxed">
              Sign in to link the Darkbloom Mac app to your account.
              <br />
              <span className="text-text-tertiary">
                My Macs shows the machines serving on your account.
              </span>
            </p>
            <button
              onClick={() => {
                trackEvent("login_cta_clicked", { source: "app_link" });
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
          </>
        )}

        {authenticated && showError && (
          <>
            <p className="text-base text-text-secondary mb-8 leading-relaxed">
              Darkbloom could not create an app session.
              <br />
              <span className="text-text-tertiary">Try handing off again.</span>
            </p>
            <button
              onClick={() => void handoff()}
              className="inline-flex items-center justify-center gap-2 px-8 py-3 rounded-lg
                         bg-coral text-white font-bold text-sm
                         hover:opacity-90 transition-all focus-ring"
            >
              Try Again
            </button>
          </>
        )}

        {authenticated && !showError && (
          <>
            <p className="text-base text-text-secondary mb-8 leading-relaxed">
              {showHandedOff ? "You're signed in." : "Handing off to the app…"}
              <br />
              <span className="text-text-tertiary">
                Return to the Darkbloom app to see your Macs.
              </span>
            </p>
            {showHandedOff && (
              <button
                onClick={() => void handoff()}
                className="inline-flex items-center justify-center gap-2 px-8 py-3 rounded-lg
                           bg-coral text-white font-bold text-sm
                           hover:opacity-90 transition-all focus-ring"
              >
                Re-open Darkbloom
              </button>
            )}
            <p className="mt-4 text-xs text-text-tertiary">
              You can close this window once the app takes over.
            </p>
          </>
        )}

        <p className="mt-12 text-xs font-mono text-text-tertiary tracking-wide">
          End-to-end encrypted · Apple Silicon · Decentralized
        </p>
      </div>
    </div>
  );
}

export default function AppLinkPage() {
  return (
    <Suspense>
      <AppLinkContent />
    </Suspense>
  );
}
