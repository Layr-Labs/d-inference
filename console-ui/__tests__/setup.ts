import "@testing-library/jest-dom/vitest";
import React from "react";
import { vi } from "vitest";
import messages from "@/i18n/messages/en.json";

function getMessage(namespace: string | undefined, key: string): string {
  const path = [...(namespace ? namespace.split(".") : []), ...key.split(".")];
  let cursor: unknown = messages;
  for (const part of path) {
    if (!cursor || typeof cursor !== "object" || !(part in cursor)) {
      return key;
    }
    cursor = (cursor as Record<string, unknown>)[part];
  }
  return typeof cursor === "string" ? cursor : key;
}

function interpolate(message: string, values?: Record<string, unknown>): string {
  if (!values) return message;
  return message.replace(/\{([a-zA-Z_][a-zA-Z0-9_]*)[^{}]*\}/g, (_, key) =>
    values[key] == null ? `{${key}}` : String(values[key])
  );
}

vi.mock("next-intl", () => ({
  hasLocale: (locales: readonly string[], locale: string | undefined) =>
    Boolean(locale && locales.includes(locale)),
  NextIntlClientProvider: ({ children }: { children: React.ReactNode }) => children,
  useLocale: () => "en",
  useTranslations: (namespace?: string) => {
    const t = (key: string, values?: Record<string, unknown>) =>
      interpolate(getMessage(namespace, key), values);
    t.rich = (key: string, values?: Record<string, unknown>) =>
      interpolate(getMessage(namespace, key), values);
    return t;
  },
}));

vi.mock("@/i18n/navigation", () => ({
  Link: ({ href, children, ...props }: { href: string; children: React.ReactNode }) => (
    React.createElement("a", { href, ...props }, children)
  ),
  usePathname: () => "/",
  useRouter: () => ({
    push: vi.fn(),
    replace: vi.fn(),
    refresh: vi.fn(),
  }),
  redirect: vi.fn(),
  getPathname: ({ href }: { href: string }) => href,
}));
