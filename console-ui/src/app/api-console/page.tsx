"use client";

import { useState, useEffect } from "react";
import { TopBar } from "@/components/TopBar";
import { CodeExample } from "@/components/CodeExample";
import { ApiKeysManager } from "@/components/api-keys";
import { trackEvent } from "@/lib/google-analytics";
import {
  ChevronDown,
  MessageSquare,
  List,
  BarChart3,
  Shield,
  CreditCard,
} from "lucide-react";

const API_KEY_STORAGE = "darkbloom_api_key";
const COORDINATOR_STORAGE = "darkbloom_coordinator_url";
const DEFAULT_COORDINATOR = "https://api.darkbloom.dev";
const EXAMPLE_MODEL = "<model-id-from-/v1/models>";

function getApiKey() {
  if (typeof window === "undefined") return "";
  return localStorage.getItem(API_KEY_STORAGE) || "";
}

function getCoordinatorUrl() {
  if (typeof window === "undefined") return DEFAULT_COORDINATOR;
  return localStorage.getItem(COORDINATOR_STORAGE) || DEFAULT_COORDINATOR;
}

const ENDPOINTS = [
  {
    method: "POST",
    path: "/v1/chat/completions",
    description: "Stream or generate chat completions (OpenAI-compatible)",
    icon: MessageSquare,
    auth: true,
    request: `{
  "model": "${EXAMPLE_MODEL}",
  "messages": [
    {"role": "system", "content": "You are a helpful assistant."},
    {"role": "user", "content": "Hello!"}
  ],
  "stream": true,
  "max_tokens": 1024
}`,
    response: `{
  "id": "chatcmpl-...",
  "object": "chat.completion.chunk",
  "model": "${EXAMPLE_MODEL}",
  "choices": [{
    "index": 0,
    "delta": {"role": "assistant", "content": "Hello"},
    "finish_reason": null
  }]
}`,
    notes: "Supports streaming (SSE) and non-streaming responses. All prompts are end-to-end encrypted. Response headers include provider attestation metadata (x-provider-attested, x-provider-trust-level, x-provider-chip).",
  },
  {
    method: "POST",
    path: "/v1/responses",
    description: "Create a model response (OpenAI Responses API)",
    icon: MessageSquare,
    auth: true,
    request: `{
  "model": "${EXAMPLE_MODEL}",
  "input": "Explain how decentralized inference works.",
  "stream": true,
  "max_output_tokens": 1024
}`,
    response: `{
  "id": "resp_...",
  "object": "response",
  "model": "${EXAMPLE_MODEL}",
  "output": [{
    "type": "message",
    "role": "assistant",
    "content": [{
      "type": "output_text",
      "text": "Decentralized inference distributes..."
    }]
  }],
  "usage": {
    "input_tokens": 12,
    "output_tokens": 256
  }
}`,
    notes: "OpenAI Responses API format. Accepts 'input' (string or array) instead of 'messages'. Uses input_tokens/output_tokens for usage. Supports streaming. Same routing, encryption, and billing as chat completions.",
  },
  {
    method: "GET",
    path: "/v1/models",
    description: "List all available models with provider coverage and pricing",
    icon: List,
    auth: true,
    response: `{
  "data": [
    {
      "id": "${EXAMPLE_MODEL}",
      "object": "model",
      "name": "Qwen3.5 27B",
      "hugging_face_id": "${EXAMPLE_MODEL}",
      "created": 1735689600,
      "description": "Balanced general-purpose model.",
      "input_modalities": ["text"],
      "output_modalities": ["text"],
      "quantization": "int8",
      "context_length": 262144,
      "max_output_length": 16384,
      "pricing": {
        "prompt": "0.00000005",
        "completion": "0.0000002",
        "image": "0",
        "request": "0",
        "input_cache_read": "0"
      },
      "supported_sampling_parameters": ["temperature", "top_p", "top_k", "stop", "seed", "max_tokens"],
      "supported_features": ["tools", "reasoning"],
      "metadata": {
        "model_type": "chat",
        "provider_count": 2,
        "trust_level": "hardware",
        "display_name": "Qwen3.5 27B"
      }
    }
  ]
}`,
    notes: "OpenAI-compatible model list. Top-level fields follow the OpenRouter provider schema (per-token USD pricing strings, modalities, supported features). Darkbloom-native fields (trust_level, provider_count) live under metadata. A dedicated OpenRouter provider feed (pure schema, no metadata) is served at GET /v1/models/openrouter.",
  },
  {
    method: "GET",
    path: "/v1/stats",
    description: "Platform statistics: active providers, models, request counts",
    icon: BarChart3,
    auth: false,
    response: `{
  "providers_online": 3,
  "providers_total": 5,
  "models_available": 4,
  "requests_24h": 1250,
  "tokens_24h": 850000,
  "attested_providers": 3
}`,
  },
  {
    method: "GET",
    path: "/v1/providers/attestation",
    description: "Full attestation chain for all online providers",
    icon: Shield,
    auth: false,
    response: `{
  "providers": [{
    "id": "...",
    "chip": "Apple M4 Max",
    "serial": "F46G****0H",
    "trust_level": "hardware",
    "secure_enclave": true,
    "sip_enabled": true,
    "mda_verified": true,
    "se_key_bound": true,
    "attestation_cert_chain": ["<PEM>", "<PEM>"]
  }]
}`,
    notes: "Publicly accessible — no authentication required. Use this to independently verify that providers are running on genuine Apple hardware with Secure Enclave attestation.",
  },
  {
    method: "GET",
    path: "/v1/pricing",
    description: "Current pricing for all models (per million tokens)",
    icon: CreditCard,
    auth: false,
    response: `{
  "prices": [
    {"model": "${EXAMPLE_MODEL}", "input_price": 100000, "output_price": 780000, "input_usd": "$0.10", "output_usd": "$0.78"}
  ]
}`,
  },
  {
    method: "GET",
    path: "/v1/payments/balance",
    description: "Check your account balance",
    icon: CreditCard,
    auth: true,
    response: `{
  "balance_micro_usd": 5000000,
  "balance_usd": 5.00
}`,
  },
  {
    method: "GET",
    path: "/v1/payments/usage",
    description: "Detailed per-request usage and cost history",
    icon: CreditCard,
    auth: true,
    response: `{
  "usage": [
    {
      "request_id": "...",
      "model": "${EXAMPLE_MODEL}",
      "prompt_tokens": 150,
      "completion_tokens": 500,
      "cost_micro_usd": 420,
      "timestamp": "2026-04-11T22:00:00Z"
    }
  ]
}`,
  },
];

function EndpointRow({
  method,
  path,
  description,
  icon: Icon,
  auth,
  request,
  response,
  notes,
}: (typeof ENDPOINTS)[0]) {
  const [expanded, setExpanded] = useState(false);

  return (
    <div className="border-b border-border-dim/50 last:border-0">
      <button
        onClick={() => {
          const nextExpanded = !expanded;
          setExpanded(nextExpanded);
          if (nextExpanded) {
            trackEvent("api_endpoint_expanded", {
              endpoint_path: path,
              http_method: method,
              requires_auth: auth,
            });
          }
        }}
        className="w-full flex items-center gap-3 px-4 py-3 text-left hover:bg-bg-hover transition-colors"
      >
        <Icon size={16} className="text-text-tertiary shrink-0" />
        <span
          className={`text-xs font-mono font-bold px-2 py-0.5 rounded ${
            method === "GET"
              ? "bg-accent-green/10 text-accent-green"
              : "bg-accent-brand/10 text-accent-brand"
          }`}
        >
          {method}
        </span>
        <span className="text-sm font-mono text-text-primary">{path}</span>
        {auth && (
          <span className="text-xs text-text-tertiary px-1.5 py-0.5 bg-bg-tertiary rounded">
            Auth
          </span>
        )}
        <span className="flex-1 text-xs text-text-tertiary text-right truncate ml-2">
          {description}
        </span>
        <ChevronDown
          size={14}
          className={`text-text-tertiary transition-transform ${expanded ? "rotate-180" : ""}`}
        />
      </button>
      {expanded && (
        <div className="px-4 pb-4 space-y-3">
          <p className="text-sm text-text-secondary">{description}</p>
          {auth && (
            <p className="text-xs text-text-tertiary">
              Requires <code className="text-accent-brand">Authorization: Bearer &lt;api_key&gt;</code> header
            </p>
          )}
          {request && (
            <div>
              <p className="text-xs font-mono text-text-tertiary mb-1.5">Request</p>
              <pre className="bg-bg-primary border border-border-dim rounded-lg px-3 py-2.5 text-xs font-mono text-text-primary overflow-x-auto whitespace-pre">{request}</pre>
            </div>
          )}
          {response && (
            <div>
              <p className="text-xs font-mono text-text-tertiary mb-1.5">Response</p>
              <pre className="bg-bg-primary border border-border-dim rounded-lg px-3 py-2.5 text-xs font-mono text-text-primary overflow-x-auto whitespace-pre">{response}</pre>
            </div>
          )}
          {notes && (
            <p className="text-xs text-text-tertiary leading-relaxed">{notes}</p>
          )}
        </div>
      )}
    </div>
  );
}

export default function ApiConsolePage() {
  const [apiKey, setApiKey] = useState("");
  const [coordinatorUrl, setCoordinatorUrl] = useState(DEFAULT_COORDINATOR);

  useEffect(() => {
    setApiKey(getApiKey());
    setCoordinatorUrl(getCoordinatorUrl());
  }, []);

  const k = apiKey || "<YOUR_API_KEY>";
  const u = coordinatorUrl;

  const sdkSetup = [
    {
      label: "cURL",
      language: "bash",
      code: `# No installation needed
export DARKBLOOM_API_KEY="${k}"
export DARKBLOOM_BASE_URL="${u}/v1"`,
    },
    {
      label: "Python",
      language: "bash",
      code: `pip install openai`,
    },
    {
      label: "TypeScript",
      language: "bash",
      code: `npm install openai`,
    },
    {
      label: "Vercel AI SDK",
      language: "bash",
      code: `npm install ai @ai-sdk/openai-compatible`,
    },
  ];

  const chatExample = [
    {
      label: "cURL",
      language: "bash",
      code: `curl -X POST ${u}/v1/chat/completions \\
  -H "Authorization: Bearer ${k}" \\
  -H "Content-Type: application/json" \\
  -d '{
    "model": "${EXAMPLE_MODEL}",
    "messages": [{"role": "user", "content": "Explain quantum computing"}],
    "stream": true,
    "max_tokens": 1024
  }'`,
    },
    {
      label: "Python",
      language: "python",
      code: `from openai import OpenAI

client = OpenAI(
    base_url="${u}/v1",
    api_key="${k}",
)

stream = client.chat.completions.create(
    model="${EXAMPLE_MODEL}",
    messages=[{"role": "user", "content": "Explain quantum computing"}],
    stream=True,
    max_tokens=1024,
)

for chunk in stream:
    content = chunk.choices[0].delta.content
    if content:
        print(content, end="", flush=True)`,
    },
    {
      label: "TypeScript",
      language: "typescript",
      code: `import OpenAI from "openai";

const client = new OpenAI({
  baseURL: "${u}/v1",
  apiKey: "${k}",
});

const stream = await client.chat.completions.create({
  model: "${EXAMPLE_MODEL}",
  messages: [{ role: "user", content: "Explain quantum computing" }],
  stream: true,
  max_tokens: 1024,
});

for await (const chunk of stream) {
  const content = chunk.choices[0]?.delta?.content;
  if (content) process.stdout.write(content);
}`,
    },
    {
      label: "Vercel AI SDK",
      language: "typescript",
      code: `import { createOpenAICompatible } from "@ai-sdk/openai-compatible";
import { generateText, streamText } from "ai";

const darkbloom = createOpenAICompatible({
  name: "darkbloom",
  baseURL: "${u}/v1",
  apiKey: "${k}",
});

// Streaming response
const { textStream } = streamText({
  model: darkbloom.chatModel("${EXAMPLE_MODEL}"),
  prompt: "Explain quantum computing",
});

for await (const text of textStream) {
  process.stdout.write(text);
}

// Single response
const { text } = await generateText({
  model: darkbloom.chatModel("${EXAMPLE_MODEL}"),
  prompt: "Write a haiku about Apple Silicon",
});
console.log(text);`,
    },
  ];

  const modelsExample = [
    {
      label: "Python",
      language: "python",
      code: `from openai import OpenAI

client = OpenAI(base_url="${u}/v1", api_key="${k}")

models = client.models.list()
for model in models.data:
    print(f"{model.id}")`,
    },
    {
      label: "cURL",
      language: "bash",
      code: `curl ${u}/v1/models \\
  -H "Authorization: Bearer ${k}"`,
    },
  ];

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
            <CodeExample examples={sdkSetup} />
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
            <CodeExample examples={chatExample} />
          </section>

          {/* List Models */}
          <section>
            <h2 className="text-lg font-semibold text-text-primary mb-2">List Models</h2>
            <p className="text-sm text-text-secondary mb-4">
              Check available models, provider counts, and attestation status.
            </p>
            <CodeExample examples={modelsExample} />
          </section>

          {/* Bottom spacer */}
          <div className="pb-8" />
        </div>
      </div>
    </div>
  );
}
