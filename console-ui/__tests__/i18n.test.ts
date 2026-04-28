import { describe, expect, it } from "vitest";
import {
  detectLocalePreference,
  localeFromCountry,
  parseAcceptLanguage,
} from "@/i18n/detection";
import en from "@/i18n/messages/en.json";
import es from "@/i18n/messages/es.json";

function flatten(obj: Record<string, unknown>, prefix = ""): Record<string, string> {
  return Object.fromEntries(
    Object.entries(obj).flatMap(([key, value]) => {
      const next = prefix ? `${prefix}.${key}` : key;
      if (value && typeof value === "object" && !Array.isArray(value)) {
        return Object.entries(flatten(value as Record<string, unknown>, next));
      }
      return [[next, String(value)]];
    })
  );
}

describe("locale detection", () => {
  it("uses manual cookie locale before browser and country hints", () => {
    expect(
      detectLocalePreference({
        cookieLocale: "fr",
        acceptLanguage: "es-MX,es;q=0.9",
        country: "DE",
      })
    ).toEqual({ locale: "fr", source: "cookie" });
  });

  it("uses browser language before IP country fallback", () => {
    expect(
      detectLocalePreference({
        acceptLanguage: "ja-JP,ja;q=0.9",
        country: "MX",
      })
    ).toEqual({ locale: "ja", source: "browser" });
  });

  it("falls back to coarse IP country when browser language is unsupported", () => {
    expect(
      detectLocalePreference({
        acceptLanguage: "sv-SE,sv;q=0.9",
        country: "BR",
      })
    ).toEqual({ locale: "pt-BR", source: "country" });
  });

  it("falls back to English when no hint matches", () => {
    expect(detectLocalePreference({ country: "US" })).toEqual({
      locale: "en",
      source: "default",
    });
  });

  it("parses weighted Accept-Language headers", () => {
    expect(parseAcceptLanguage("nl-NL;q=0.9,de-DE;q=0.8,es;q=1")).toBe("es");
  });

  it("maps countries to supported locales", () => {
    expect(localeFromCountry("MX")).toBe("es");
    expect(localeFromCountry("JP")).toBe("ja");
    expect(localeFromCountry("CN")).toBe("zh-CN");
  });
});

describe("message catalogs", () => {
  it("keeps locale files key-compatible with English", () => {
    expect(Object.keys(flatten(es)).sort()).toEqual(Object.keys(flatten(en)).sort());
  });
});
