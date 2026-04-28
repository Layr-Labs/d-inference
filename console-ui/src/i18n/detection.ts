import {
  defaultLocale,
  isLocale,
  localeCookieName,
  locales,
  type Locale,
} from "./locales";

const countryLocaleMap: Record<string, Locale> = {
  AR: "es",
  BO: "es",
  CL: "es",
  CO: "es",
  CR: "es",
  CU: "es",
  DO: "es",
  EC: "es",
  ES: "es",
  GT: "es",
  HN: "es",
  MX: "es",
  NI: "es",
  PA: "es",
  PE: "es",
  PR: "es",
  PY: "es",
  SV: "es",
  UY: "es",
  VE: "es",
  FR: "fr",
  BE: "fr",
  MC: "fr",
  SN: "fr",
  CI: "fr",
  DE: "de",
  AT: "de",
  CH: "de",
  IT: "it",
  SM: "it",
  VA: "it",
  NL: "nl",
  BR: "pt-BR",
  PT: "pt-BR",
  JP: "ja",
  KR: "ko",
  CN: "zh-CN",
  SG: "zh-CN",
  TW: "zh-TW",
  HK: "zh-TW",
  IN: "hi",
  BD: "bn",
  AE: "ar",
  SA: "ar",
  EG: "ar",
  QA: "ar",
  RU: "ru",
  ID: "id",
  VN: "vi",
  TH: "th",
  TR: "tr",
  PL: "pl",
  UA: "uk",
};

export function matchSupportedLocale(value: string | null | undefined): Locale | null {
  if (!value) return null;
  const normalized = value.trim();
  if (isLocale(normalized)) return normalized;
  const lower = normalized.toLowerCase();

  for (const locale of locales) {
    if (locale.toLowerCase() === lower) return locale;
  }

  const language = lower.split("-")[0];
  for (const locale of locales) {
    if (locale.toLowerCase().split("-")[0] === language) return locale;
  }

  return null;
}

export function parseAcceptLanguage(header: string | null | undefined): Locale | null {
  if (!header) return null;
  return header
    .split(",")
    .map((entry) => {
      const [tag, qPart] = entry.trim().split(";q=");
      const q = qPart ? Number.parseFloat(qPart) : 1;
      return { tag, q: Number.isFinite(q) ? q : 0 };
    })
    .sort((a, b) => b.q - a.q)
    .map(({ tag }) => matchSupportedLocale(tag))
    .find((locale): locale is Locale => Boolean(locale)) ?? null;
}

export function localeFromCountry(country: string | null | undefined): Locale | null {
  if (!country) return null;
  return countryLocaleMap[country.trim().toUpperCase()] ?? null;
}

export function detectLocalePreference(input: {
  cookieLocale?: string | null;
  acceptLanguage?: string | null;
  country?: string | null;
}): { locale: Locale; source: "cookie" | "browser" | "country" | "default" } {
  const cookieLocale = matchSupportedLocale(input.cookieLocale);
  if (cookieLocale) return { locale: cookieLocale, source: "cookie" };

  const browserLocale = parseAcceptLanguage(input.acceptLanguage);
  if (browserLocale) return { locale: browserLocale, source: "browser" };

  const countryLocale = localeFromCountry(input.country);
  if (countryLocale) return { locale: countryLocale, source: "country" };

  return { locale: defaultLocale, source: "default" };
}

export function localeCookieHeader(locale: Locale): string {
  return `${localeCookieName}=${locale}; Path=/; Max-Age=31536000; SameSite=Lax`;
}
