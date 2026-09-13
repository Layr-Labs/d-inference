"use client";

import Link from "next/link";
import { ArrowRight, CheckCircle2 } from "lucide-react";
import { useAuthContext } from "@/components/providers/PrivyClientProvider";
import { ProviderRequirements } from "./ProviderRequirements";
import { ProviderQuestions } from "./ProviderQuestions";
import { SetupCommand } from "./SetupCommand";
import { SETUP_STEPS } from "./content";

const ACTION_CLASS = "inline-flex min-h-11 items-center justify-center gap-2 rounded-lg bg-accent-brand px-4 text-sm font-medium text-white transition-opacity hover:opacity-90 disabled:cursor-wait disabled:opacity-50 dark:text-bg-primary";

export function ProviderOnboarding({ hasLinkedProviders = false }: { hasLinkedProviders?: boolean }) {
  const { ready, authenticated, login } = useAuthContext();

  return (
    <div className="mx-auto max-w-5xl px-5 pb-12 pt-8 sm:px-8 sm:pt-12">
      <header className="border-b border-border-dim pb-8 sm:pb-10">
        <h1 className="font-logo text-4xl font-normal tracking-tight text-text-primary sm:text-5xl">
          {hasLinkedProviders ? "Add another Mac." : "Put your Mac to work."}
        </h1>
        <p className="mt-4 max-w-2xl text-base leading-relaxed text-text-secondary">
          {hasLinkedProviders
            ? "Connect another Apple Silicon Mac to your account. Run these four steps on the Mac you’re adding, then manage it alongside your other providers."
            : "Earn by serving AI models on your Apple Silicon Mac. Install the provider, link your account, and bring your Mac onto the network."}
        </p>
        <div className="mt-5 flex flex-wrap items-center gap-x-6 gap-y-2 text-sm">
          <span className="text-text-secondary">Four steps, from Terminal to your dashboard</span>
          {hasLinkedProviders && <Link href="/providers" className="inline-flex min-h-9 items-center gap-1.5 font-medium text-accent-brand hover:underline">Back to your providers<ArrowRight size={14} aria-hidden /></Link>}
        </div>
      </header>

      <div className="grid gap-9 py-8 sm:py-10 lg:grid-cols-[240px_minmax(0,1fr)] lg:gap-12">
        <ProviderRequirements />
        <section aria-label="Provider setup steps" className="min-w-0">
          <ol>
            {SETUP_STEPS.map((step, index) => (
              <li key={step.id} id={`provider-${step.id}`} className="relative scroll-mt-6 pb-8 pl-11 last:pb-0 sm:pl-12">
                {index < SETUP_STEPS.length - 1 && <span aria-hidden className="absolute bottom-0 left-3.5 top-9 w-px bg-border-dim" />}
                <span aria-hidden className="absolute left-0 top-0 flex size-7 items-center justify-center rounded-full bg-accent-brand-dim text-xs font-medium text-accent-brand">{index + 1}</span>
                <h2 className="pt-0.5 text-base font-medium text-text-primary">{step.title}</h2>
                <p className="mb-4 mt-2 text-sm leading-relaxed text-text-secondary">{step.description}</p>
                <SetupCommand command={step.command} label={step.title} />
                <p className="mt-3 text-xs leading-relaxed text-text-secondary">{step.note}</p>
                {step.id === "link" && (
                  <div className="mt-4">
                    {authenticated ? (
                      <p className="flex items-center gap-2 text-xs text-text-secondary"><CheckCircle2 size={15} aria-hidden className="shrink-0 text-accent-brand" />You’re signed in. Approve the code to connect this Mac.</p>
                    ) : (
                      <button type="button" onClick={login} disabled={!ready} className={ACTION_CLASS}>{ready ? "Sign in to link your Mac" : "Loading sign-in…"}<ArrowRight size={15} aria-hidden /></button>
                    )}
                    <Link href="/link" className="mt-2 inline-flex min-h-9 items-center text-xs font-medium text-accent-brand hover:underline">Already have a code? Enter it here</Link>
                  </div>
                )}
                {step.id === "start" && <p className="mt-3 text-xs leading-relaxed text-text-secondary">By starting the provider, you agree to the <a href="https://darkbloom.dev/terms.html" className="text-accent-brand underline underline-offset-2">Terms of Service</a>.</p>}
                {step.id === "check" && (
                  <div className="mt-5">
                    {authenticated ? <Link href="/providers" className={ACTION_CLASS}>Open provider dashboard<ArrowRight size={15} aria-hidden /></Link> : <button type="button" onClick={login} disabled={!ready} className={ACTION_CLASS}>{ready ? "Sign in to check your Mac" : "Loading sign-in…"}<ArrowRight size={15} aria-hidden /></button>}
                  </div>
                )}
              </li>
            ))}
          </ol>
        </section>
      </div>

      <ProviderQuestions />
    </div>
  );
}
