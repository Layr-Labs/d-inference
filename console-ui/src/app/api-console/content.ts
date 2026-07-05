import {
  MessageSquare,
  List,
  BarChart3,
  Shield,
  CreditCard,
  type LucideIcon,
} from "lucide-react";

export const EXAMPLE_MODEL = "<model-id-from-/v1/models>";

export interface Endpoint {
  method: "GET" | "POST";
  path: string;
  description: string;
  icon: LucideIcon;
  auth: boolean;
  request?: string;
  response?: string;
  notes?: string;
}

export interface CodeSnippet {
  label: string;
  language: string;
  code: string;
}

// Static endpoint reference. Pure data — no React, no hooks (proposal F7/F8).
export const ENDPOINTS: Endpoint[] = [
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
      "name": "Gemma 4 26B",
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
        "display_name": "Gemma 4 26B"
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
    {"model": "${EXAMPLE_MODEL}", "input_price": 50000, "output_price": 200000, "input_usd": "$0.05", "output_usd": "$0.20"}
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

/** SDK install snippets, parameterized by the user's key + coordinator URL. */
export function sdkSetupExamples(apiKey: string, baseUrl: string): CodeSnippet[] {
  return [
    {
      label: "cURL",
      language: "bash",
      code: `# No installation needed
export DARKBLOOM_API_KEY="${apiKey}"
export DARKBLOOM_BASE_URL="${baseUrl}/v1"`,
    },
    { label: "Python", language: "bash", code: `pip install openai` },
    { label: "TypeScript", language: "bash", code: `npm install openai` },
    { label: "Vercel AI SDK", language: "bash", code: `npm install ai @ai-sdk/openai-compatible` },
  ];
}

/** Chat-completion call snippets across SDKs. */
export function chatExamples(apiKey: string, baseUrl: string): CodeSnippet[] {
  return [
    {
      label: "cURL",
      language: "bash",
      code: `curl -X POST ${baseUrl}/v1/chat/completions \\
  -H "Authorization: Bearer ${apiKey}" \\
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
    base_url="${baseUrl}/v1",
    api_key="${apiKey}",
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
  baseURL: "${baseUrl}/v1",
  apiKey: "${apiKey}",
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
  baseURL: "${baseUrl}/v1",
  apiKey: "${apiKey}",
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
}

/** List-models call snippets. */
export function modelsExamples(apiKey: string, baseUrl: string): CodeSnippet[] {
  return [
    {
      label: "Python",
      language: "python",
      code: `from openai import OpenAI

client = OpenAI(base_url="${baseUrl}/v1", api_key="${apiKey}")

models = client.models.list()
for model in models.data:
    print(f"{model.id}")`,
    },
    {
      label: "cURL",
      language: "bash",
      code: `curl ${baseUrl}/v1/models \\
  -H "Authorization: Bearer ${apiKey}"`,
    },
  ];
}
