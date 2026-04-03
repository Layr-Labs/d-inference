import type { Metadata } from "next";
import { Inter, JetBrains_Mono } from "next/font/google";
import "./globals.css";
import { AppShell } from "@/components/AppShell";
import { ThemeProvider } from "@/components/providers/ThemeProvider";
import { PrivyClientProvider } from "@/components/providers/PrivyClientProvider";

const inter = Inter({
  variable: "--font-inter",
  subsets: ["latin"],
  weight: ["400", "500", "600", "700"],
});

const jetbrains = JetBrains_Mono({
  variable: "--font-jetbrains",
  subsets: ["latin"],
  weight: ["400", "500", "600"],
});

export const metadata: Metadata = {
  title: "EigenInference — Eigen Labs Research Project",
  description:
    "Private AI inference through hardware-attested Apple Silicon providers. Your prompts stay encrypted, your data stays yours.",
  icons: {
    icon: "/favicon.ico",
  },
};

export default function RootLayout({
  children,
}: {
  children: React.ReactNode;
}) {
  return (
    <html lang="en" suppressHydrationWarning>
      <body
        className={`${inter.variable} ${jetbrains.variable} font-sans antialiased`}
      >
        <ThemeProvider>
          <PrivyClientProvider>
            <AppShell>{children}</AppShell>
          </PrivyClientProvider>
        </ThemeProvider>
      </body>
    </html>
  );
}
