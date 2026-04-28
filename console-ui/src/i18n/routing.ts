import { defineRouting } from "next-intl/routing";
import { defaultLocale, localeCookieName, locales } from "./locales";

export const routing = defineRouting({
  locales,
  defaultLocale,
  localePrefix: "as-needed",
  localeCookie: {
    name: localeCookieName,
    maxAge: 60 * 60 * 24 * 365,
  },
});

