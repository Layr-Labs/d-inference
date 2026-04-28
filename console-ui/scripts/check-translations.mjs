import fs from "node:fs";
import path from "node:path";

const root = process.cwd();
const messagesDir = path.join(root, "src/i18n/messages");
const locales = [
  "en",
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

function readJson(file) {
  return JSON.parse(fs.readFileSync(file, "utf8"));
}

function flatten(obj, prefix = "") {
  const out = new Map();
  for (const [key, value] of Object.entries(obj)) {
    const next = prefix ? `${prefix}.${key}` : key;
    if (value && typeof value === "object" && !Array.isArray(value)) {
      for (const [childKey, childValue] of flatten(value, next)) {
        out.set(childKey, childValue);
      }
    } else {
      out.set(next, value);
    }
  }
  return out;
}

function placeholders(value) {
  if (typeof value !== "string") return [];
  const tokens = new Set();

  for (let i = 0; i < value.length; i++) {
    if (value[i] !== "{") continue;

    let depth = 1;
    let j = i + 1;
    while (j < value.length && depth > 0) {
      if (value[j] === "{") depth++;
      if (value[j] === "}") depth--;
      j++;
    }

    if (depth === 0) {
      const body = value.slice(i + 1, j - 1).trim();
      const name = body.match(/^([a-zA-Z_][a-zA-Z0-9_]*)/)?.[1];
      if (name) tokens.add(name);
      i = j - 1;
    }
  }

  for (const match of value.matchAll(/<([a-zA-Z][a-zA-Z0-9]*)>/g)) {
    tokens.add(`<${match[1]}>`);
  }
  for (const match of value.matchAll(/<\/([a-zA-Z][a-zA-Z0-9]*)>/g)) {
    tokens.add(`</${match[1]}>`);
  }
  return [...tokens].sort();
}

function sameArray(a, b) {
  return a.length === b.length && a.every((value, index) => value === b[index]);
}

const source = flatten(readJson(path.join(messagesDir, "en.json")));
const errors = [];

for (const locale of locales) {
  const file = path.join(messagesDir, `${locale}.json`);
  if (!fs.existsSync(file)) {
    errors.push(`${locale}: missing message file`);
    continue;
  }

  let target;
  try {
    target = flatten(readJson(file));
  } catch (error) {
    errors.push(`${locale}: invalid JSON: ${error.message}`);
    continue;
  }

  for (const key of source.keys()) {
    if (!target.has(key)) {
      errors.push(`${locale}: missing key ${key}`);
      continue;
    }
    const value = target.get(key);
    if (typeof value !== "string" || value.trim() === "") {
      errors.push(`${locale}: empty/non-string value for ${key}`);
      continue;
    }
    const sourceTokens = placeholders(source.get(key));
    const targetTokens = placeholders(value);
    if (!sameArray(sourceTokens, targetTokens)) {
      errors.push(
        `${locale}: placeholder mismatch for ${key}: expected ${sourceTokens.join(",") || "none"} got ${targetTokens.join(",") || "none"}`
      );
    }
  }

  for (const key of target.keys()) {
    if (!source.has(key)) {
      errors.push(`${locale}: extra key ${key}`);
    }
  }
}

if (errors.length) {
  console.error(errors.join("\n"));
  process.exit(1);
}

console.log(`i18n check passed for ${locales.length} locales and ${source.size} keys`);
