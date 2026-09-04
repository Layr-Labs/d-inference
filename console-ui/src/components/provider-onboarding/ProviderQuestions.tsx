import { ChevronDown } from "lucide-react";
import { PROVIDER_FAQS } from "./content";

export function ProviderQuestions() {
  return (
    <section aria-labelledby="provider-questions" className="border-t border-border-dim pt-8">
      <h2 id="provider-questions" className="text-xl font-medium tracking-tight text-text-primary">A few things to know</h2>
      <div className="mt-4 divide-y divide-border-dim">
        {PROVIDER_FAQS.map(({ question, answer }) => (
          <details key={question} className="group">
            <summary className="flex min-h-14 cursor-pointer list-none items-center justify-between gap-4 rounded-md py-4 text-sm font-medium text-text-primary [&::-webkit-details-marker]:hidden">
              {question}<ChevronDown aria-hidden size={16} className="shrink-0 text-text-secondary transition-transform group-open:rotate-180 motion-reduce:transition-none" />
            </summary>
            <p className="max-w-3xl pb-5 text-sm leading-relaxed text-text-secondary">{answer}</p>
          </details>
        ))}
      </div>
    </section>
  );
}
