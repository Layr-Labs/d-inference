import type { Metadata, Viewport } from "next";
import { publicStructuredData, siteDescription, siteOrigin } from "../content/public-site";
import "./globals.css";
import "./footer.css";
import "./navigation.css";
import "./r9.css";

// Keeps the browser chrome and overscroll surfaces black, so route changes
// never flash a light frame around the experience.
export const viewport: Viewport = {
  themeColor: "#000000",
};

export const metadata: Metadata = {
  metadataBase: new URL(siteOrigin),
  title: {
    default: "Darkbloom — The compute grid powered by people",
    template: "%s — Darkbloom",
  },
  description: siteDescription,
  icons: {
    icon: "/favicon.svg",
    shortcut: "/favicon.svg",
  },
  openGraph: {
    title: "The compute grid powered by people.",
    description: "For the innovators pushing the frontier.",
    type: "website",
    siteName: "Darkbloom",
    images: [{ url: `${siteOrigin}/og.png`, width: 1440, height: 835, alt: "The compute grid powered by people." }],
  },
  twitter: {
    card: "summary_large_image",
    title: "The compute grid powered by people.",
    description: "For the innovators pushing the frontier.",
    images: [`${siteOrigin}/og.png`],
  },
};

export default function RootLayout({
  children,
}: Readonly<{
  children: React.ReactNode;
}>) {
  return (
    <html lang="en" className="scroll-smooth" data-scroll-behavior="smooth">
      <body>
        <script
          type="application/ld+json"
          dangerouslySetInnerHTML={{ __html: JSON.stringify(publicStructuredData).replace(/</g, "\\u003c") }}
        />
        {children}
      </body>
    </html>
  );
}
