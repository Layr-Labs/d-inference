import type { Metadata } from "next";
import Link from "next/link";
import { Suspense } from "react";
import { ProviderWaitlistForm } from "./ProviderWaitlistForm";

export const metadata: Metadata = {
  title: "Provider hardware interest — Darkbloom",
  description:
    "Register interest in running a Darkbloom provider on your Apple Silicon machine.",
};

export default function ProviderWaitlistPage() {
  return (
    <div className="min-h-full bg-bg-primary">
      <div className="border-b border-border-dim">
        <div className="mx-auto flex max-w-5xl items-center justify-between px-6 py-4">
          <Link
            href="/"
            className="text-xl text-text-primary focus-ring"
            style={{
              fontFamily: "'Louize', Georgia, serif",
              letterSpacing: "-0.02em",
            }}
          >
            Darkbloom
          </Link>
          <Link
            href="/earn"
            className="text-sm font-medium text-text-secondary transition-colors hover:text-text-primary focus-ring"
          >
            Provider earnings
          </Link>
        </div>
      </div>

      <main className="mx-auto grid max-w-5xl gap-12 px-6 py-12 lg:grid-cols-[minmax(0,1fr)_minmax(360px,440px)] lg:items-start lg:py-20">
        <section className="pt-2 lg:pt-8">
          <div className="mb-6 flex items-center gap-2 text-sm font-medium text-accent-amber">
            <span
              className="h-2 w-2 rounded-full bg-accent-amber"
              aria-hidden="true"
            />
            Provider admission is hardware-gated
          </div>
          <h1
            className="max-w-xl text-4xl leading-[1.08] text-text-primary sm:text-5xl"
            style={{
              fontFamily: "'Louize', Georgia, serif",
              letterSpacing: "-0.035em",
            }}
          >
            Your Mac may be a fit as the network expands.
          </h1>
          <p className="mt-5 max-w-xl text-base leading-relaxed text-text-secondary">
            Darkbloom adjusts provider capacity by verified hardware profile.
            Tell us what you run so we can measure demand for future hardware
            support. Automated eligibility emails are not active yet.
          </p>

          <div className="mt-10 max-w-lg border-l border-border-default pl-5">
            <p className="text-sm font-medium text-text-primary">
              What happens next
            </p>
            <ol className="mt-4 space-y-4 text-sm leading-relaxed text-text-secondary">
              <li className="flex gap-3">
                <span className="font-mono text-xs text-text-tertiary">01</span>
                We record the hardware configuration you submit.
              </li>
              <li className="flex gap-3">
                <span className="font-mono text-xs text-text-tertiary">02</span>
                The provider team uses aggregated registrations to plan capacity.
              </li>
              <li className="flex gap-3">
                <span className="font-mono text-xs text-text-tertiary">03</span>
                Any future email flow will verify address ownership before sending.
              </li>
            </ol>
          </div>
        </section>

        <Suspense
          fallback={
            <div className="h-[520px] animate-pulse rounded-2xl border border-border-dim bg-bg-secondary" />
          }
        >
          <ProviderWaitlistForm />
        </Suspense>
      </main>
    </div>
  );
}
