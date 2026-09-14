import type { Metadata } from "next";
import type { ReactNode } from "react";
import { Analytics } from "../components/analytics";
import "./globals.css";

const description =
  "Private AI inference on a network of verified Apple Silicon Macs. Build with OpenAI-compatible APIs, transparent token pricing, and hardware-backed privacy.";

export const metadata: Metadata = {
  metadataBase: new URL("https://darkbloom.dev"),
  title: "Darkbloom — Private inference. Open possibilities.",
  description,
  alternates: { canonical: "/" },
  icons: { icon: "/icon.svg" },
  openGraph: {
    title: "Darkbloom — Private inference. Open possibilities.",
    description,
    url: "/",
    siteName: "Darkbloom",
    type: "website",
  },
  twitter: {
    card: "summary",
    site: "@eigen_labs",
    title: "Darkbloom — Private AI inference",
    description,
  },
};

export default function RootLayout({ children }: { children: ReactNode }) {
  return (
    <html lang="en">
      <body>
        {children}
        <Analytics />
      </body>
    </html>
  );
}
