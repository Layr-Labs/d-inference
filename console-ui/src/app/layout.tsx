import { ModelTokenPromotionsProvider } from "@/components/app-providers/ModelTokenPromotionsProvider";
import type { Metadata } from "next";
import "./globals.css";
import { AppShell } from "@/components/AppShell";
import { GoogleAnalytics } from "@/components/GoogleAnalytics";
import { Analytics } from "@vercel/analytics/next";
import { ThemeProvider } from "@/components/app-providers/ThemeProvider";
import { PrivyClientProvider } from "@/components/app-providers/PrivyClientProvider";
import { VerificationModeProvider } from "@/components/app-providers/verification-mode";
import { TelemetryInitializer } from "@/components/TelemetryInitializer";
import { DatadogRUM } from "@/components/DatadogRUM";
import { THEME_INIT_SCRIPT } from "@/lib/theme";

export const metadata: Metadata = {
  title: "Darkbloom — Private AI on Verified Macs",
  description:
    "Private AI inference through hardware-attested Apple Silicon providers. Encrypted connections. Verified providers.",
  icons: {
    icon: [
      { url: "/favicon.ico", sizes: "any" },
      { url: "/favicon.svg", type: "image/svg+xml" },
    ],
  },
};

export default function RootLayout({
  children,
}: {
  children: React.ReactNode;
}) {
  return (
    <html lang="en" suppressHydrationWarning>
      <head>
        <script dangerouslySetInnerHTML={{ __html: THEME_INIT_SCRIPT }} />
        {/* Preload the shared brand font for navigation and page content. */}
        <link
          rel="preload"
          href="/fonts/PPTelegraf-Regular.woff2"
          as="font"
          type="font/woff2"
          crossOrigin="anonymous"
        />
      </head>
      <body className="font-sans antialiased">
        <Analytics />
        <GoogleAnalytics />
        <TelemetryInitializer />
        <DatadogRUM />
        <ThemeProvider>
          <PrivyClientProvider>
            <ModelTokenPromotionsProvider>
            <VerificationModeProvider>
              <AppShell>{children}</AppShell>
            </VerificationModeProvider>
          </ModelTokenPromotionsProvider>
          </PrivyClientProvider>
        </ThemeProvider>
      </body>
    </html>
  );
}
