"use client";

import Link from "next/link";
import { Cpu, ArrowRight, Mail, Terminal } from "lucide-react";
import { trackEvent } from "@/lib/google-analytics";

export function SetupProviderCTA({
  authenticated,
  ready,
  login,
}: {
  authenticated: boolean;
  ready: boolean;
  login: () => void;
}) {
  return (
    <div className="rounded-xl bg-bg-secondary p-6 mb-6">
      {!authenticated ? (
        <div className="flex flex-col sm:flex-row items-start sm:items-center justify-between gap-4">
          <div className="flex items-start gap-3">
            <div className="w-10 h-10 rounded-lg bg-accent-brand/10 flex items-center justify-center shrink-0">
              <Terminal size={20} className="text-accent-brand" />
            </div>
            <div>
              <h3 className="text-sm font-semibold text-text-primary mb-0.5">
                Ready to start earning?
              </h3>
              <p className="text-sm text-text-secondary">
                Sign in to set up your provider node and start earning from your Mac.
              </p>
            </div>
          </div>
          <button
            onClick={() => {
              trackEvent("login_cta_clicked", { source: "earn_page_setup_provider_cta" });
              login();
            }}
            disabled={!ready}
            className="inline-flex items-center justify-center gap-2 px-6 py-2.5 rounded-lg
                       bg-coral text-white font-medium text-sm
                       hover:opacity-90
                       disabled:opacity-40 disabled:cursor-not-allowed
                       transition-all shrink-0"
          >
            <Mail size={14} />
            {!ready ? "Loading..." : "Sign In"}
          </button>
        </div>
      ) : (
        <div className="flex flex-col sm:flex-row items-start sm:items-center justify-between gap-4">
          <div className="flex items-start gap-3">
            <div className="w-10 h-10 rounded-lg bg-accent-green/10 flex items-center justify-center shrink-0">
              <Cpu size={20} className="text-accent-green" />
            </div>
            <div>
              <h3 className="text-sm font-semibold text-text-primary mb-0.5">
                Turn your Mac into a provider
              </h3>
              <p className="text-sm text-text-secondary">
                Set up your Apple Silicon Mac to serve inference and earn from the Darkbloom network.
              </p>
            </div>
          </div>
          <Link
            href="/providers/setup"
            onClick={() => {
              trackEvent("provider_setup_clicked", { source: "earn_page_setup_provider_cta" });
            }}
            className="inline-flex items-center justify-center gap-2 px-6 py-2.5 rounded-lg
                       bg-accent-brand text-white font-medium text-sm
                       hover:bg-accent-brand-hover
                       transition-colors shrink-0"
          >
            Setup Provider <ArrowRight size={14} />
          </Link>
        </div>
      )}
    </div>
  );
}
