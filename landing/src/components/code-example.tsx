"use client";

import { useState } from "react";
import { CopyButton } from "./copy-button";

const examples = {
  Python: `from openai import OpenAI

client = OpenAI(
    base_url="https://api.darkbloom.dev/v1",
    api_key="YOUR_DARKBLOOM_API_KEY",
)

stream = client.chat.completions.create(
    model="gemma-4-26b",
    messages=[{"role": "user", "content": "Hello, Darkbloom."}],
    stream=True,
)

for chunk in stream:
    print(chunk.choices[0].delta.content or "", end="")`,
  cURL: `curl https://api.darkbloom.dev/v1/chat/completions \\
  -H "Authorization: Bearer $DARKBLOOM_API_KEY" \\
  -H "Content-Type: application/json" \\
  -d '{
    "model": "gemma-4-26b",
    "messages": [
      {"role": "user", "content": "Hello, Darkbloom."}
    ],
    "stream": true
  }'`,
};

function Highlight({ code }: { code: string }) {
  return code
    .split(/("(?:[^"\\]|\\.)*"|\b(?:from|import|for|in|True)\b)/g)
    .map((part, index) => (
      <span
        key={index}
        className={
          part.startsWith('"')
            ? "code-string"
            : /^(from|import|for|in|True)$/.test(part)
              ? "code-keyword"
              : undefined
        }
      >
        {part}
      </span>
    ));
}

export function CodeExample() {
  const [language, setLanguage] = useState<keyof typeof examples>("Python");
  return (
    <div className="code-window">
      <div className="code-toolbar">
        <div className="code-tabs" aria-label="Code language">
          {(Object.keys(examples) as (keyof typeof examples)[]).map((name) => (
            <button
              key={name}
              type="button"
              aria-pressed={language === name}
              onClick={() => setLanguage(name)}
            >
              {name}
            </button>
          ))}
        </div>
        <CopyButton
          key={language}
          text={examples[language]}
          label={`Copy ${language} example`}
        />
      </div>
      <pre tabIndex={0} aria-label={`${language} API example`}>
        <code>
          <Highlight code={examples[language]} />
        </code>
      </pre>
      <div className="code-footer">
        <span className="status-dot" />
        <span>YOUR EXISTING SDK. A NEW BASE URL.</span>
      </div>
    </div>
  );
}
