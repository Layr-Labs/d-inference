"use client";

import { useState, useEffect } from "react";
import { TopBar } from "@/components/TopBar";
import { CodeExample } from "@/components/CodeExample";
import { ApiKeysManager } from "@/components/api-keys";
import { STORAGE_KEYS } from "@/lib/constants";
import { clientCoordinatorUrl, PUBLIC_COORDINATOR_URL } from "@/lib/coordinator-url";
import {
  ENDPOINTS,
  EXAMPLE_MODEL,
  sdkSetupExamples,
  chatExamples,
  modelsExamples,
} from "./content";
import { EndpointRow } from "./EndpointRow";

export default function ApiConsolePage() {
  const [apiKey, setApiKey] = useState("");
  const [coordinatorUrl, setCoordinatorUrl] = useState(PUBLIC_COORDINATOR_URL);

  useEffect(() => {
    setApiKey(localStorage.getItem(STORAGE_KEYS.apiKey) || "");
    setCoordinatorUrl(clientCoordinatorUrl());
  }, []);

  const k = apiKey || "<YOUR_API_KEY>";
  const u = coordinatorUrl;

  return (
    <div className="flex flex-col h-full">
      <TopBar title="API Console" />
      <div className="flex-1 overflow-y-auto">
        <div className="max-w-4xl mx-auto p-6 space-y-8">
          <div className="rounded-xl bg-accent-amber/5 border border-accent-amber/15 px-5 py-4">
            <p className="text-sm text-text-secondary leading-relaxed">
              <span className="font-semibold text-text-primary">Darkbloom API</span>{" "}
              — OpenAI-compatible. Swap your base URL, keep your existing code.
              Every request is end-to-end encrypted and processed on hardware-attested Apple Silicon.
            </p>
          </div>

          {/* Endpoint Reference — first */}
          <section>
            <h2 className="text-lg font-semibold text-text-primary mb-4">Endpoint Reference</h2>
            <p className="text-sm text-text-secondary mb-4">
              Expand each endpoint to see request/response format and notes.
            </p>
            <div className="rounded-xl bg-bg-secondary shadow-sm overflow-hidden">
              {ENDPOINTS.map((ep) => (
                <EndpointRow key={ep.path + ep.method} {...ep} />
              ))}
            </div>
          </section>

          {/* Base URL */}
          <section>
            <div className="rounded-xl bg-bg-secondary shadow-sm p-5">
              <h3 className="text-sm font-semibold text-text-primary mb-2">Base URL</h3>
              <p className="text-sm font-mono text-accent-brand">{coordinatorUrl}/v1</p>
              <p className="text-xs text-text-tertiary mt-2">
                All endpoints are relative to this base URL. Provider attestation and pricing endpoints are publicly accessible without authentication.
              </p>
            </div>
          </section>

          {/* API Key Management */}
          <ApiKeysManager onConsoleKeyChange={setApiKey} />

          {/* SDK Setup */}
          <section>
            <h2 className="text-lg font-semibold text-text-primary mb-2">Quick Start</h2>
            <p className="text-sm text-text-secondary mb-4">
              Install the OpenAI SDK or Vercel AI SDK. The Darkbloom API is fully OpenAI-compatible — just change the base URL.
            </p>
            <CodeExample examples={sdkSetupExamples(k, u)} />
          </section>

          {/* Available Models */}
          <section>
            <h2 className="text-lg font-semibold text-text-primary mb-2">Available Models</h2>
            <div className="rounded-xl bg-bg-secondary shadow-sm overflow-hidden">
              <table className="w-full">
                <thead>
                  <tr className="border-b border-border-dim">
                    <th className="text-left text-xs text-text-tertiary font-medium px-4 py-3">Model ID</th>
                    <th className="text-left text-xs text-text-tertiary font-medium px-4 py-3">Type</th>
                    <th className="text-left text-xs text-text-tertiary font-medium px-4 py-3">Architecture</th>
                  </tr>
                </thead>
                <tbody>
                  {[
                    { id: EXAMPLE_MODEL, type: "text", arch: "Returned by /v1/models" },
                  ].map((m) => (
                    <tr key={m.id} className="border-b border-border-dim/50 last:border-0">
                      <td className="px-4 py-2.5 text-sm font-mono text-text-primary">{m.id}</td>
                      <td className="px-4 py-2.5">
                        <span className="text-xs font-mono px-2 py-0.5 rounded bg-accent-brand/10 text-accent-brand">{m.type}</span>
                      </td>
                      <td className="px-4 py-2.5 text-xs text-text-tertiary">{m.arch}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
            <p className="text-xs text-text-tertiary mt-2">
              Model availability depends on online providers. Check <code className="text-accent-brand">/v1/models</code> for real-time availability.
            </p>
          </section>

          {/* Chat Completions */}
          <section>
            <h2 className="text-lg font-semibold text-text-primary mb-2">Chat Completions</h2>
            <p className="text-sm text-text-secondary mb-4">
              Stream chat completions with any supported model. Supports system messages, multi-turn conversations, and thinking/reasoning output.
            </p>
            <CodeExample examples={chatExamples(k, u)} />
          </section>

          {/* List Models */}
          <section>
            <h2 className="text-lg font-semibold text-text-primary mb-2">List Models</h2>
            <p className="text-sm text-text-secondary mb-4">
              Check available models, provider counts, and attestation status.
            </p>
            <CodeExample examples={modelsExamples(k, u)} />
          </section>

          {/* Bottom spacer */}
          <div className="pb-8" />
        </div>
      </div>
    </div>
  );
}
