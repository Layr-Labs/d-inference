import type { Metadata } from "next";
import "./globals.css";

export const metadata: Metadata = {
  title: "Darkbloom Admin Console",
  description: "Administrative dashboard for EigenInference coordinator operations.",
};

export default function RootLayout({ children }: Readonly<{ children: React.ReactNode }>) {
  return (
    <html lang="en">
      <body>{children}</body>
    </html>
  );
}
