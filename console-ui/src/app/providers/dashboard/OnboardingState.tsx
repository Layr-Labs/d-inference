// Shown when the account has zero linked machines. Sells the earning potential,
// gives the three concrete steps with a copyable install command, and explains
// in one line why the network is trustworthy.

import Link from "next/link";
import { ArrowRight, Cpu, ShieldCheck, TrendingUp, Zap } from "lucide-react";
import { CopyCommand } from "./gauges/CopyCommand";
import { INSTALL_COMMAND } from "./fixes";

const POTENTIAL = [
  { machine: "M-series Mac, 32–64GB", fit: "Small & mid-size text models", note: "Good pilot node" },
  { machine: "Mac Studio, 96–128GB", fit: "Larger MoE models", note: "Higher routing capacity" },
  { machine: "Ultra-class, 192GB+", fit: "Premium large models", note: "Best earning ceiling" },
];

const STEPS = [
  { icon: Cpu, title: "Install", detail: "Download the provider CLI on your Mac." },
  { icon: ShieldCheck, title: "Link", detail: "Run darkbloom login and approve the device." },
  { icon: Zap, title: "Serve", detail: "Start the daemon and pick supported models." },
];

export function OnboardingState() {
  return (
    <div className="space-y-5">
      <div className="rounded-xl bg-bg-secondary shadow-sm p-6">
        <div className="grid gap-6 lg:grid-cols-[1.1fr_0.9fr]">
          <div>
            <div className="inline-flex items-center gap-2 rounded-full bg-accent-brand/10 px-3 py-1 text-xs font-medium text-accent-brand mb-4">
              <TrendingUp size={13} />
              Earning potential
            </div>
            <h2 className="text-xl font-bold text-text-primary">No provider machines linked yet</h2>
            <p className="text-sm text-text-secondary mt-2 max-w-xl">
              Link an Apple Silicon Mac to start seeing live health, routing eligibility, per-machine
              earnings, and the attestation chain right here.
            </p>

            <div className="grid gap-3 mt-5 sm:grid-cols-3">
              {POTENTIAL.map((item) => (
                <div key={item.machine} className="rounded-lg bg-bg-primary/60 p-3">
                  <p className="text-xs font-semibold text-text-primary">{item.machine}</p>
                  <p className="text-[11px] text-text-secondary mt-1">{item.fit}</p>
                  <p className="text-[11px] text-text-tertiary mt-2">{item.note}</p>
                </div>
              ))}
            </div>

            <div className="mt-5">
              <p className="text-[10px] uppercase tracking-wider text-text-tertiary mb-1.5">Install in one line</p>
              <CopyCommand command={INSTALL_COMMAND} />
            </div>

            <div className="flex flex-wrap gap-3 mt-6">
              <Link
                href="/providers/setup"
                className="inline-flex items-center gap-1.5 px-4 py-2 rounded-lg bg-accent-brand text-white text-sm font-medium hover:bg-accent-brand-hover transition-colors"
              >
                Set up a provider <ArrowRight size={14} />
              </Link>
              <Link
                href="/earn"
                className="inline-flex items-center gap-1.5 px-4 py-2 rounded-lg bg-bg-tertiary text-text-primary text-sm font-medium hover:bg-bg-hover transition-colors"
              >
                Open calculator <ArrowRight size={14} />
              </Link>
            </div>
          </div>

          <div className="space-y-3">
            {STEPS.map(({ icon: Icon, title, detail }) => (
              <div key={title} className="flex items-start gap-3 rounded-lg bg-bg-primary/60 p-3">
                <Icon size={16} className="text-accent-brand mt-0.5 shrink-0" />
                <div>
                  <p className="text-sm font-semibold text-text-primary">{title}</p>
                  <p className="text-xs text-text-secondary mt-0.5">{detail}</p>
                </div>
              </div>
            ))}
            <div className="flex items-start gap-3 rounded-lg bg-accent-green/8 p-3">
              <ShieldCheck size={16} className="text-accent-green mt-0.5 shrink-0" />
              <div>
                <p className="text-sm font-semibold text-text-primary">Hardware-attested by design</p>
                <p className="text-xs text-text-secondary mt-0.5">
                  Secure Enclave → MDM → Apple Device Attestation. The coordinator never sees your
                  prompts and only routes to verified devices.
                </p>
              </div>
            </div>
          </div>
        </div>
      </div>
    </div>
  );
}
