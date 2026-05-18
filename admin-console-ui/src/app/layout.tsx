import type { Metadata } from "next";
import "./globals.css";
import { AdminPrivyClientProvider } from "@/components/providers/privy-client-provider";

export const metadata: Metadata = {
  title: "Darkbloom Admin Console",
  description: "Administrative dashboard for Darkbloom coordinator operations.",
};

export default function RootLayout({ children }: Readonly<{ children: React.ReactNode }>) {
  return (
    <html lang="en">
      <body>
        <AdminPrivyClientProvider>{children}</AdminPrivyClientProvider>
      </body>
    </html>
  );
}
