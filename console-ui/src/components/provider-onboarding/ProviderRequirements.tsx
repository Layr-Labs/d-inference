import Link from "next/link";
import { Cpu, Monitor, PlugZap } from "lucide-react";
import { MIN_PROVIDER_MEMORY_GB } from "@/app/earn/providerReadiness";

const REQUIREMENTS = [
  { icon: Cpu, title: "Apple Silicon", detail: `${MIN_PROVIDER_MEMORY_GB} GB or more of unified memory` },
  { icon: Monitor, title: "macOS 26 or later", detail: "Tahoe or a newer version" },
  { icon: PlugZap, title: "Power and a stable connection", detail: "Keep your Mac awake and online while serving" },
];

export function ProviderRequirements() {
  return (
    <aside aria-labelledby="provider-requirements" className="lg:sticky lg:top-8 lg:self-start">
      <h2 id="provider-requirements" className="text-base font-medium text-text-primary">Before you begin</h2>
      <p className="mt-2 text-sm leading-relaxed text-text-secondary">Check your chip, memory, and macOS version in Apple menu → About This Mac.</p>
      <ul className="mt-5 space-y-5">
        {REQUIREMENTS.map(({ icon: Icon, title, detail }) => (
          <li key={title} className="flex items-start gap-3">
            <Icon size={18} aria-hidden className="mt-0.5 shrink-0 text-accent-brand" />
            <div>
              <p className="text-sm font-medium text-text-primary">{title}</p>
              <p className="mt-1 text-xs leading-relaxed text-text-secondary">{detail}</p>
            </div>
          </li>
        ))}
      </ul>
      <p className="mt-5 text-xs leading-relaxed text-text-secondary">Models also need free disk space. The picker shows download sizes before you choose.</p>
      <div className="mt-6 border-t border-border-dim pt-5">
        <p className="text-sm font-medium text-text-primary">Exploring what your Mac could earn?</p>
        <Link href="/earn" className="mt-2 inline-flex min-h-9 items-center text-sm font-medium text-accent-brand hover:underline">Open the earnings calculator</Link>
        <p className="mt-1 text-xs leading-relaxed text-text-secondary">Have less than {MIN_PROVIDER_MEMORY_GB} GB? You can register interest there as support expands.</p>
      </div>
    </aside>
  );
}
