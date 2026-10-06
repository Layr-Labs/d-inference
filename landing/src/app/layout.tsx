import type { Metadata, Viewport } from "next";
import { headers } from "next/headers";
import "./globals.css";
import "./footer.css";
import "./navigation.css";
import "./r9.css";

// Keeps the browser chrome and overscroll surfaces black, so route changes
// never flash a light frame around the experience.
export const viewport: Viewport = {
  themeColor: "#000000",
};

export async function generateMetadata(): Promise<Metadata> {
  const requestHeaders = await headers();
  const host = requestHeaders.get("x-forwarded-host") ?? requestHeaders.get("host") ?? "darkbloom.dev";
  const protocol = requestHeaders.get("x-forwarded-proto") ?? (host.includes("localhost") ? "http" : "https");
  const origin = `${protocol}://${host}`;
  return {
    metadataBase: new URL(origin),
    title: {
      default: "Darkbloom — The compute grid powered by people",
      template: "%s — Darkbloom",
    },
    description:
      "The compute grid powered by people. For the innovators pushing the frontier.",
    icons: {
      icon: "/favicon.svg",
      shortcut: "/favicon.svg",
    },
    openGraph: {
      title: "The compute grid powered by people.",
      description: "For the innovators pushing the frontier.",
      type: "website",
      siteName: "Darkbloom",
      images: [{ url: `${origin}/og.png`, width: 1440, height: 835, alt: "The compute grid powered by people." }],
    },
    twitter: {
      card: "summary_large_image",
      title: "The compute grid powered by people.",
      description: "For the innovators pushing the frontier.",
      images: [`${origin}/og.png`],
    },
  };
}

export default function RootLayout({
  children,
}: Readonly<{
  children: React.ReactNode;
}>) {
  return (
    <html lang="en" className="scroll-smooth" data-scroll-behavior="smooth">
      <body>{children}</body>
    </html>
  );
}
