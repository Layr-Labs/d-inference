export const defaultLocale = "en";

export const locales = [
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
] as const;

export type Locale = (typeof locales)[number];

export const localeCookieName = "darkbloom_locale";

export const localeLabels: Record<Locale, string> = {
  en: "English",
  es: "Español",
  fr: "Français",
  de: "Deutsch",
  "pt-BR": "Português (Brasil)",
  it: "Italiano",
  nl: "Nederlands",
  ja: "日本語",
  ko: "한국어",
  "zh-CN": "简体中文",
  "zh-TW": "繁體中文",
  hi: "हिन्दी",
  bn: "বাংলা",
  ar: "العربية",
  ru: "Русский",
  id: "Bahasa Indonesia",
  vi: "Tiếng Việt",
  th: "ไทย",
  tr: "Türkçe",
  pl: "Polski",
  uk: "Українська",
};

export function isLocale(value: string | null | undefined): value is Locale {
  return locales.includes(value as Locale);
}
