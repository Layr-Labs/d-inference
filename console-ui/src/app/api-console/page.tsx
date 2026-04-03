"use client";

import { useState, useEffect, useCallback } from "react";
import { TopBar } from "@/components/TopBar";
import { CodeExample } from "@/components/CodeExample";
import {
  Key,
  Copy,
  Check,
  RefreshCw,
  Eye,
  EyeOff,
  ChevronDown,
  MessageSquare,
  Mic,
  List,
  BarChart3,
  Shield,
  CreditCard,
} from "lucide-react";

const API_KEY_STORAGE = "eigeninference_api_key";
const COORDINATOR_STORAGE = "eigeninference_coordinator_url";
const DEFAULT_COORDINATOR = "https://inference-test.openinnovation.dev";

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
  },
  {
    method: "POST",
    path: "/v1/audio/transcriptions",
    description: "Transcribe audio files to text (multipart form data)",
    icon: Mic,
    auth: true,
  },
  {
    method: "GET",
    path: "/v1/models",
    description: "List all available models with provider coverage",
    icon: List,
    auth: true,
  },
  {
    method: "GET",
    path: "/v1/stats",
    description: "Platform statistics and provider metrics",
    icon: BarChart3,
    auth: false,
  },
  {
    method: "GET",
    path: "/v1/providers/attestation",
    description: "Provider attestation data and hardware security details",
    icon: Shield,
    auth: false,
  },
  {
    method: "GET",
    path: "/v1/payments/balance",
    description: "Check your account balance",
    icon: CreditCard,
    auth: true,
  },
  {
    method: "GET",
    path: "/v1/payments/usage",
    description: "Detailed per-request usage and cost history",
    icon: CreditCard,
    auth: true,
  },
  {
    method: "POST",
    path: "/v1/payments/deposit",
    description: "Deposit funds to your account",
    icon: CreditCard,
    auth: true,
  },
];

function EndpointRow({
  method,
  path,
  description,
  icon: Icon,
  auth,
}: (typeof ENDPOINTS)[0]) {
  const [expanded, setExpanded] = useState(false);

  return (
    <div className="border-b border-border-dim/50 last:border-0">
      <button
        onClick={() => setExpanded(!expanded)}
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
        <div className="px-4 pb-4 text-sm text-text-secondary">
          <p className="mb-2">{description}</p>
          {auth && (
            <p className="text-xs text-text-tertiary">
              Requires <code className="text-accent-brand">Authorization: Bearer &lt;api_key&gt;</code> header
            </p>
          )}
        </div>
      )}
    </div>
  );
}

export default function ApiConsolePage() {
  const [apiKey, setApiKey] = useState("");
  const [showKey, setShowKey] = useState(false);
  const [copied, setCopied] = useState(false);
  const [generating, setGenerating] = useState(false);
  const [coordinatorUrl, setCoordinatorUrl] = useState(DEFAULT_COORDINATOR);

  useEffect(() => {
    setApiKey(getApiKey());
    setCoordinatorUrl(getCoordinatorUrl());
  }, []);

  const maskedKey = apiKey
    ? `${apiKey.slice(0, 8)}${"•".repeat(20)}${apiKey.slice(-4)}`
    : "No API key generated";

  const copyKey = useCallback(() => {
    if (!apiKey) return;
    navigator.clipboard.writeText(apiKey);
    setCopied(true);
    setTimeout(() => setCopied(false), 2000);
  }, [apiKey]);

  const generateKey = useCallback(async () => {
    setGenerating(true);
    try {
      const res = await fetch("/api/auth/keys", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
      });
      if (res.ok) {
        const { api_key } = await res.json();
        localStorage.setItem(API_KEY_STORAGE, api_key);
        setApiKey(api_key);
      }
    } catch {
      // failed
    } finally {
      setGenerating(false);
    }
  }, []);

  const chatExample = [
    {
      label: "cURL",
      language: "bash",
      code: `curl -X POST ${coordinatorUrl}/v1/chat/completions \\
  -H "Authorization: Bearer ${apiKey || '<YOUR_API_KEY>'}" \\
  -H "Content-Type: application/json" \\
  -d '{
    "model": "Qwen/Qwen3-8B-MLX-4bit",
    "messages": [{"role": "user", "content": "Hello!"}],
    "stream": true
  }'`,
    },
    {
      label: "Python",
      language: "python",
      code: `from openai import OpenAI

client = OpenAI(
    base_url="${coordinatorUrl}/v1",
    api_key="${apiKey || '<YOUR_API_KEY>'}",
)

response = client.chat.completions.create(
    model="Qwen/Qwen3-8B-MLX-4bit",
    messages=[{"role": "user", "content": "Hello!"}],
    stream=True,
)

for chunk in response:
    if chunk.choices[0].delta.content:
        print(chunk.choices[0].delta.content, end="")`,
    },
    {
      label: "TypeScript",
      language: "typescript",
      code: `import OpenAI from "openai";

const client = new OpenAI({
  baseURL: "${coordinatorUrl}/v1",
  apiKey: "${apiKey || '<YOUR_API_KEY>'}",
});

const stream = await client.chat.completions.create({
  model: "Qwen/Qwen3-8B-MLX-4bit",
  messages: [{ role: "user", content: "Hello!" }],
  stream: true,
});

for await (const chunk of stream) {
  process.stdout.write(chunk.choices[0]?.delta?.content || "");
}`,
    },
  ];

  const modelsExample = [
    {
      label: "cURL",
      language: "bash",
      code: `curl ${coordinatorUrl}/v1/models \\
  -H "Authorization: Bearer ${apiKey || '<YOUR_API_KEY>'}"`,
    },
    {
      label: "Python",
      language: "python",
      code: `import requests

response = requests.get(
    "${coordinatorUrl}/v1/models",
    headers={"Authorization": "Bearer ${apiKey || '<YOUR_API_KEY>'}"}
)
models = response.json()["data"]
for model in models:
    print(f"{model['id']} - {model.get('provider_count', 0)} providers")`,
    },
  ];

  return (
    <div className="flex flex-col h-full">
      <TopBar title="API Console" />
      <div className="flex-1 overflow-y-auto">
        <div className="max-w-4xl mx-auto p-6 space-y-8">
          <div className="rounded-xl bg-accent-amber/5 border border-accent-amber/15 px-5 py-4">
            <p className="text-sm text-text-secondary leading-relaxed">
              <span className="font-semibold text-text-primary">Research Preview API.</span>{" "}
              This API is part of an experimental research project and is subject to change.
              Endpoints, pricing, and availability may be modified without notice as we iterate.
              Not recommended for production dependencies.
            </p>
          </div>

          {/* API Key Management */}
          <section>
            <h2 className="text-lg font-semibold text-text-primary mb-4">API Key</h2>
            <div className="rounded-xl bg-bg-secondary shadow-sm p-5">
              <div className="flex items-center gap-3">
                <Key size={18} className="text-accent-brand shrink-0" />
                <div className="flex-1 min-w-0">
                  <p className="text-sm font-mono text-text-primary truncate">
                    {showKey ? apiKey || "No key generated" : maskedKey}
                  </p>
                </div>
                <button
                  onClick={() => setShowKey(!showKey)}
                  className="p-2 rounded-lg hover:bg-bg-hover text-text-tertiary hover:text-text-secondary transition-colors"
                  title={showKey ? "Hide key" : "Show key"}
                >
                  {showKey ? <EyeOff size={16} /> : <Eye size={16} />}
                </button>
                <button
                  onClick={copyKey}
                  disabled={!apiKey}
                  className="p-2 rounded-lg hover:bg-bg-hover text-text-tertiary hover:text-text-secondary transition-colors disabled:opacity-30"
                  title="Copy key"
                >
                  {copied ? <Check size={16} className="text-accent-green" /> : <Copy size={16} />}
                </button>
                <button
                  onClick={generateKey}
                  disabled={generating}
                  className="flex items-center gap-2 px-4 py-2 rounded-lg bg-accent-brand text-white text-sm font-medium hover:bg-accent-brand-hover transition-colors disabled:opacity-50"
                >
                  <RefreshCw size={14} className={generating ? "animate-spin" : ""} />
                  {apiKey ? "Regenerate" : "Generate"}
                </button>
              </div>
              <p className="mt-3 text-xs text-text-tertiary">
                Use this key in the <code className="text-accent-brand">Authorization: Bearer</code> header for all authenticated API requests.
              </p>
            </div>
          </section>

          {/* Endpoint Reference */}
          <section>
            <h2 className="text-lg font-semibold text-text-primary mb-4">Endpoints</h2>
            <div className="rounded-xl bg-bg-secondary shadow-sm overflow-hidden">
              {ENDPOINTS.map((ep) => (
                <EndpointRow key={ep.path + ep.method} {...ep} />
              ))}
            </div>
          </section>

          {/* Code Examples */}
          <section>
            <h2 className="text-lg font-semibold text-text-primary mb-4">Chat Completions</h2>
            <p className="text-sm text-text-secondary mb-4">
              The API is OpenAI-compatible. Use any OpenAI SDK by pointing it at the EigenInference coordinator.
            </p>
            <CodeExample examples={chatExample} />
          </section>

          <section>
            <h2 className="text-lg font-semibold text-text-primary mb-4">List Models</h2>
            <CodeExample examples={modelsExample} />
          </section>
        </div>
      </div>
    </div>
  );
}
