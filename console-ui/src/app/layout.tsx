import type { Metadata } from "next";
import "./globals.css";
import { AppShell } from "@/components/AppShell";
import { ThemeProvider } from "@/components/providers/ThemeProvider";
import { PrivyClientProvider } from "@/components/providers/PrivyClientProvider";
import { VerificationModeProvider } from "@/lib/verification-mode";

export const metadata: Metadata = {
  title: "Darkbloom — Private AI on Verified Macs",
  description:
    "Private AI inference through hardware-attested Apple Silicon providers. Your prompts stay encrypted, your data stays yours.",
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
      <body className="font-sans antialiased">
        <ThemeProvider>
          <PrivyClientProvider>
            <VerificationModeProvider>
              <AppShell>{children}</AppShell>
            </VerificationModeProvider>
          </PrivyClientProvider>
        </ThemeProvider>
      </body>
    </html>
  );
}
