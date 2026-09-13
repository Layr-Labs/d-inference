"use client";

import Link from "next/link";
import { useState, useEffect } from "react";
import { ArrowUpRight, BookOpen, KeyRound } from "lucide-react";
import { TopBar } from "@/components/TopBar";
import { CodeExample } from "@/components/CodeExample";
import { ApiKeysManager } from "@/components/api-keys";
import { STORAGE_KEYS } from "@/lib/constants";
import { PUBLIC_COORDINATOR_URL } from "@/lib/coordinator-url";
import { apiExampleUrl } from "@/lib/api-example-url";
import { ENDPOINTS, sdkSetupExamples, chatExamples, modelsExamples } from "./content";
import { EndpointRow } from "./EndpointRow";
import { BaseUrl } from "./BaseUrl";

const SECTIONS = [
  { href: "#quick-start", label: "Quick start" },
  { href: "#api-keys", label: "API keys" },
  { href: "#endpoints", label: "Endpoints" },
  { href: "#examples", label: "Examples" },
];

export default function ApiConsolePage() {
  const [apiKey, setApiKey] = useState("");
  const [exampleUrl, setExampleUrl] = useState(PUBLIC_COORDINATOR_URL);

  useEffect(() => {
    setApiKey(localStorage.getItem(STORAGE_KEYS.apiKey) || "");
    setExampleUrl(apiExampleUrl().replace(/\/$/, ""));
  }, []);

  const key = apiKey || "<YOUR_API_KEY>";

  return (
    <div className="flex h-full flex-col">
      <TopBar title="API Console" />
      <div className="flex-1 overflow-y-auto scroll-smooth motion-reduce:scroll-auto">
        <div className="mx-auto max-w-5xl px-5 pb-12 pt-8 sm:px-10 sm:pt-12">
          <header className="mb-8 flex flex-wrap items-end justify-between gap-6">
            <div className="max-w-xl">
              <h1 className="font-logo text-4xl font-normal tracking-tight text-text-primary sm:text-5xl">Build with Darkbloom</h1>
              <p className="mt-3 text-sm leading-relaxed text-text-secondary">Connect with the OpenAI SDK, choose a model, and send your first request.</p>
            </div>
            <a href="#api-keys" className="inline-flex min-h-10 items-center gap-2 rounded-lg bg-accent-brand px-4 text-sm font-medium text-white dark:text-bg-primary transition-opacity hover:opacity-90"><KeyRound size={15} />Manage API keys</a>
          </header>

          <BaseUrl url={`${exampleUrl}/v1`} />

          <nav aria-label="API documentation sections" className="sticky top-0 z-10 -mx-5 mb-9 mt-7 flex gap-6 overflow-x-auto border-b border-border-dim bg-bg-primary/95 px-5 backdrop-blur-sm sm:-mx-10 sm:gap-8 sm:px-10">
            {SECTIONS.map((section) => <a key={section.href} href={section.href} className="shrink-0 border-b-2 border-transparent py-4 text-sm font-medium text-text-secondary transition-colors hover:border-accent-brand hover:text-accent-brand">{section.label}</a>)}
          </nav>

          <div className="space-y-12">
            <section id="quick-start" className="scroll-mt-20">
              <div className="mb-5 flex flex-wrap items-start justify-between gap-4">
                <div>
                  <h2 className="text-xl font-medium tracking-tight text-text-primary">Quick start</h2>
                  <p className="mt-2 max-w-2xl text-sm leading-relaxed text-text-secondary">Install your preferred SDK and point it to Darkbloom. {apiKey ? "Your console key is included in these examples." : "Create an API key below, then add it to the example."}</p>
                </div>
                <Link href="/models" className="inline-flex items-center gap-1 text-sm font-medium text-accent-brand hover:underline">Browse models<ArrowUpRight size={15} /></Link>
              </div>
              <CodeExample examples={sdkSetupExamples(key, exampleUrl)} />
              <p className="mt-3 text-xs leading-relaxed text-text-secondary">Replace the model placeholder with an ID returned by <code className="text-text-primary">/v1/models</code>. Availability depends on connected providers.</p>
            </section>

            <div id="api-keys" className="scroll-mt-20 border-t border-border-dim pt-9">
              <ApiKeysManager onConsoleKeyChange={setApiKey} />
            </div>

            <section id="endpoints" className="scroll-mt-20 border-t border-border-dim pt-9">
              <div className="mb-5 flex items-start justify-between gap-5">
                <div>
                  <h2 className="text-xl font-medium tracking-tight text-text-primary">Endpoint reference</h2>
                  <p className="mt-2 text-sm leading-relaxed text-text-secondary">Request formats, responses, and authentication requirements.</p>
                </div>
                <span className="shrink-0 pt-1 text-sm text-text-secondary">{ENDPOINTS.length} endpoints</span>
              </div>
              <div className="border-y border-border-dim">
                {ENDPOINTS.map((endpoint) => <EndpointRow key={endpoint.path + endpoint.method} {...endpoint} />)}
              </div>
            </section>

            <section id="examples" className="scroll-mt-20 border-t border-border-dim pt-9">
              <h2 className="text-xl font-medium tracking-tight text-text-primary">Request examples</h2>
              <div className="mt-6 space-y-8">
                <div>
                  <h3 className="text-sm font-medium text-text-primary">Chat completions</h3>
                  <p className="mb-4 mt-2 text-sm leading-relaxed text-text-secondary">Stream a response, continue a conversation, or set a system message.</p>
                  <CodeExample examples={chatExamples(key, exampleUrl)} />
                </div>
                <div>
                  <h3 className="text-sm font-medium text-text-primary">List models</h3>
                  <p className="mb-4 mt-2 text-sm leading-relaxed text-text-secondary">Find model IDs and current provider coverage before sending a request.</p>
                  <CodeExample examples={modelsExamples(key, exampleUrl)} />
                </div>
              </div>
            </section>

            <div className="flex flex-wrap items-center justify-between gap-4 border-t border-border-dim pt-6">
              <p className="flex items-center gap-2 text-sm text-text-secondary"><BookOpen size={16} />Need to change your example URL?</p>
              <Link href="/settings" className="text-sm font-medium text-accent-brand hover:underline">Open settings</Link>
            </div>
          </div>
        </div>
      </div>
    </div>
  );
}
