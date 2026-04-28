import { NextRequest, NextResponse } from "next/server";
import createMiddleware from "next-intl/middleware";
import { defaultLocale, isLocale, localeCookieName } from "@/i18n/locales";
import { detectLocalePreference, localeCookieHeader } from "@/i18n/detection";
import { routing } from "@/i18n/routing";

export default function proxy(request: NextRequest) {
  const { pathname, search } = request.nextUrl;
  const handleI18nRouting = createMiddleware(routing);
  const firstSegment = pathname.split("/").filter(Boolean)[0];
  const hasLocalePrefix = isLocale(firstSegment);

  // Redirect legacy /login to root — auth is handled via in-page modal now
  if (pathname === "/login" || (hasLocalePrefix && pathname === `/${firstSegment}/login`)) {
    const url = request.nextUrl.clone();
    url.pathname =
      hasLocalePrefix && firstSegment !== defaultLocale ? `/${firstSegment}` : "/";
    return NextResponse.redirect(url);
  }

  if (!hasLocalePrefix) {
    const detected = detectLocalePreference({
      cookieLocale: request.cookies.get(localeCookieName)?.value,
      acceptLanguage: request.headers.get("accept-language"),
      country:
        request.headers.get("x-vercel-ip-country") ||
        request.headers.get("cf-ipcountry") ||
        request.headers.get("x-country-code"),
    });

    if (detected.source === "country" && detected.locale !== defaultLocale) {
      const url = request.nextUrl.clone();
      url.pathname = `/${detected.locale}${pathname === "/" ? "" : pathname}`;
      url.search = search;
      const response = NextResponse.redirect(url);
      response.headers.append("set-cookie", localeCookieHeader(detected.locale));
      return response;
    }
  }

  return handleI18nRouting(request);
}

export const config = {
  matcher: ["/((?!api|_next|_vercel|.*\\..*).*)"],
};
