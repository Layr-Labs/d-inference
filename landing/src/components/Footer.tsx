"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";
import type { ReactNode } from "react";
import { socialLinks } from "../content/site";

export function Footer({ disclaimer }: { disclaimer?: string }) {
  const pathname = usePathname();

  const scrollToTop = () => {
    const handled = !window.dispatchEvent(new Event("darkbloom:scroll-top", { cancelable: true }));
    if (!handled) window.scrollTo({ top: 0, behavior: "smooth" });
  };

  const handleHomeLink = (event: React.MouseEvent<HTMLAnchorElement>) => {
    if (pathname !== "/") return;
    event.preventDefault();
    scrollToTop();
  };

  return (
    <footer className={`footer ${disclaimer ? "footer--with-disclaimer" : ""}`} id="footer">
      <div className="footer-brand">
        <Link className="footer-logo" href="/" onClick={handleHomeLink} aria-label="Darkbloom — back to the opening film">
          <span aria-hidden="true" />
        </Link>
        <p>
          <span>Copyright © 2026</span>
          <a className="footer-eigen-link" href="https://www.eigenlabs.org/" target="_blank" rel="noreferrer">Eigen Labs, Inc.</a>
        </p>
      </div>
      {disclaimer && <p className="footer-disclaimer">{disclaimer}</p>}
      <div className="footer-column">
        <p className="footer-label">About</p>
        <Link href="/about#pricing">Pricing</Link>
        <Link href="/about#privacy">Privacy</Link>
        <Link href="/about#security">Security</Link>
        <Link href="/about#compute">Compute</Link>
        <Link href="/about#earn">Earn</Link>
      </div>
      <div className="footer-column footer-column--legal">
        <p className="footer-label">Legal</p>
        <div className="footer-legal-links">
          <Link href="/terms">Terms of service</Link>
          <Link href="/privacy">Privacy policy</Link>
        </div>
      </div>
      <div className="footer-column footer-column--connect">
        <p className="footer-label">Connect</p>
        {socialLinks.map((link) => (
          <a key={link.label} href={link.href} target="_blank" rel="noreferrer">{link.label}</a>
        ))}
      </div>
      <button className="back-to-top" type="button" onClick={scrollToTop}>Back to top ↑</button>
    </footer>
  );
}

export function FooterReveal({ disclaimer }: { disclaimer?: string }) {
  return (
    <div className={`footer-reveal ${disclaimer ? "footer-reveal--with-disclaimer" : ""}`}>
      <Footer disclaimer={disclaimer} />
    </div>
  );
}

export function PageWithFooter({
  children,
  className,
  footerDisclaimer,
}: {
  children: ReactNode;
  className: string;
  footerDisclaimer?: string;
}) {
  return (
    <>
      <main className={`${className} page-surface`}>
        {children}
      </main>
      <FooterReveal disclaimer={footerDisclaimer} />
    </>
  );
}
