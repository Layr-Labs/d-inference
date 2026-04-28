import type { Metadata } from "next";
import "../globals.css";
import { AppShell } from "@/components/AppShell";
import { GoogleAnalytics } from "@/components/GoogleAnalytics";
import { ThemeProvider } from "@/components/providers/ThemeProvider";
import { PrivyClientProvider } from "@/components/providers/PrivyClientProvider";
import { VerificationModeProvider } from "@/lib/verification-mode";
import { TelemetryInitializer } from "@/components/TelemetryInitializer";
import { DatadogRUM } from "@/components/DatadogRUM";
import { hasLocale, NextIntlClientProvider } from "next-intl";
import { getMessages, getTranslations, setRequestLocale } from "next-intl/server";
import { notFound } from "next/navigation";
import { routing } from "@/i18n/routing";

type Props = {
  children: React.ReactNode;
  params: Promise<{ locale: string }>;
};

export function generateStaticParams() {
  return routing.locales.map((locale) => ({ locale }));
}

export async function generateMetadata({ params }: Props): Promise<Metadata> {
  const { locale } = await params;
  const t = await getTranslations({ locale, namespace: "Metadata" });
  return {
    title: t("title"),
    description: t("description"),
    icons: {
      icon: [
        { url: "/favicon.ico", sizes: "any" },
        { url: "/favicon.svg", type: "image/svg+xml" },
      ],
    },
  };
}

export default async function RootLayout({ children, params }: Props) {
  const { locale } = await params;
  if (!hasLocale(routing.locales, locale)) {
    notFound();
  }

  setRequestLocale(locale);
  const messages = await getMessages();

  return (
    <html lang={locale} suppressHydrationWarning>
      <body className="font-sans antialiased">
        <NextIntlClientProvider messages={messages}>
          <GoogleAnalytics />
          <TelemetryInitializer />
          <DatadogRUM />
          <ThemeProvider>
            <PrivyClientProvider>
              <VerificationModeProvider>
                <AppShell>{children}</AppShell>
              </VerificationModeProvider>
            </PrivyClientProvider>
          </ThemeProvider>
        </NextIntlClientProvider>
      </body>
    </html>
  );
}
