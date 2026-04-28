import fs from "node:fs";
import path from "node:path";

const root = process.cwd();
const messagesDir = path.join(root, "src/i18n/messages");
const sourceFile = path.join(messagesDir, "en.json");
const model = process.env.OPENROUTER_TRANSLATION_MODEL || "google/gemini-3-flash-preview";
const apiKey = process.env.OPENROUTER_API_KEY;
const force = process.argv.includes("--force") || process.env.I18N_FORCE === "1";
const locales = [
  "es",
  "fr",
  "de",
  "pt-BR",
  "it",
  "nl",
  "ja",
  "ko",
  "zh-CN",
  "zh-TW",
  "hi",
  "bn",
  "ar",
  "ru",
  "id",
  "vi",
  "th",
  "tr",
  "pl",
  "uk",
];

const localeNames = {
  es: "Spanish",
  fr: "French",
  de: "German",
  "pt-BR": "Brazilian Portuguese",
  it: "Italian",
  nl: "Dutch",
  ja: "Japanese",
  ko: "Korean",
  "zh-CN": "Simplified Chinese",
  "zh-TW": "Traditional Chinese",
  hi: "Hindi",
  bn: "Bengali",
  ar: "Arabic",
  ru: "Russian",
  id: "Indonesian",
  vi: "Vietnamese",
  th: "Thai",
  tr: "Turkish",
  pl: "Polish",
  uk: "Ukrainian",
};

if (!apiKey) {
  console.error("OPENROUTER_API_KEY is required");
  process.exit(1);
}

function readJson(file, fallback) {
  if (!fs.existsSync(file)) return fallback;
  return JSON.parse(fs.readFileSync(file, "utf8"));
}

function flatten(obj, prefix = "") {
  const out = {};
  for (const [key, value] of Object.entries(obj)) {
    const next = prefix ? `${prefix}.${key}` : key;
    if (value && typeof value === "object" && !Array.isArray(value)) {
      Object.assign(out, flatten(value, next));
    } else {
      out[next] = value;
    }
  }
  return out;
}

function setDeep(target, dottedKey, value) {
  const parts = dottedKey.split(".");
  let cursor = target;
  for (const part of parts.slice(0, -1)) {
    cursor[part] ??= {};
    cursor = cursor[part];
  }
  cursor[parts.at(-1)] = value;
}

function unflatten(flat) {
  const out = {};
  for (const [key, value] of Object.entries(flat)) {
    setDeep(out, key, value);
  }
  return out;
}

function extractJson(text) {
  const trimmed = text.trim();
  if (trimmed.startsWith("{")) return JSON.parse(trimmed);
  const match = trimmed.match(/```(?:json)?\s*([\s\S]*?)```/);
  if (match) return JSON.parse(match[1]);
  throw new Error("Model did not return JSON");
}

async function translateBatch(locale, batch) {
  const response = await fetch("https://openrouter.ai/api/v1/chat/completions", {
    method: "POST",
    headers: {
      Authorization: `Bearer ${apiKey}`,
      "Content-Type": "application/json",
      "HTTP-Referer": "https://console.darkbloom.dev",
      "X-Title": "Darkbloom console i18n seed",
    },
    body: JSON.stringify({
      model,
      temperature: 0.1,
      response_format: { type: "json_object" },
      messages: [
        {
          role: "system",
          content:
            "You are a professional software UI localizer. Return strict JSON only. Preserve every key exactly. Translate values only. Preserve ICU placeholders like {count}, rich text tags like <code>, product names (Darkbloom, Eigen Labs, Apple Silicon, Secure Enclave), API paths, model IDs, env vars, URLs, and code literals. Do not add comments.",
        },
        {
          role: "user",
          content: JSON.stringify({
            target_locale: locale,
            target_language: localeNames[locale],
            source_language: "English",
            strings: batch,
          }),
        },
      ],
    }),
  });

  if (!response.ok) {
    throw new Error(`OpenRouter ${response.status}: ${await response.text()}`);
  }

  const data = await response.json();
  const content = data.choices?.[0]?.message?.content;
  if (!content) throw new Error("OpenRouter returned no message content");
  const parsed = extractJson(content);
  return parsed.strings && typeof parsed.strings === "object" ? parsed.strings : parsed;
}

const source = readJson(sourceFile);
const sourceFlat = flatten(source);

for (const locale of locales) {
  const targetFile = path.join(messagesDir, `${locale}.json`);
  const existing = readJson(targetFile, {});
  const existingFlat = flatten(existing);
  const nextFlat = {};
  const missing = {};

  for (const [key, value] of Object.entries(sourceFlat)) {
    if (!force && typeof existingFlat[key] === "string" && existingFlat[key].trim()) {
      nextFlat[key] = existingFlat[key];
    } else {
      missing[key] = value;
    }
  }

  const entries = Object.entries(missing);
  for (let i = 0; i < entries.length; i += 40) {
    const batch = Object.fromEntries(entries.slice(i, i + 40));
    if (!Object.keys(batch).length) continue;
    console.log(`${locale}: translating ${i + 1}-${Math.min(i + 40, entries.length)} of ${entries.length}`);
    const translated = await translateBatch(locale, batch);
    for (const [key, value] of Object.entries(translated)) {
      nextFlat[key] = String(value);
    }
  }

  fs.writeFileSync(targetFile, `${JSON.stringify(unflatten(nextFlat), null, 2)}\n`);
  console.log(`${locale}: wrote ${targetFile}`);
}
