"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";
import { Logo } from "./Logo";
import { primaryLinks } from "../content/site";

export function SiteNav({ blue = false }: { blue?: boolean }) {
  const pathname = usePathname();
  const activeLabel = pathname.startsWith("/about")
    ? "About"
    : pathname.startsWith("/docs")
      ? "Docs"
      : null;

  return (
    <header className={`site-nav ${blue ? "site-nav--blue" : ""}`}>
      <Logo />
      <nav aria-label="Primary navigation">
        {primaryLinks.map((link) => {
          const isActive = activeLabel === link.label;
          const stateClass = activeLabel ? (isActive ? "is-active" : "is-inactive") : undefined;

          return "external" in link && link.external ? (
            <a
              className={stateClass}
              key={link.label}
              href={link.href}
              target="_blank"
              rel="noreferrer"
              aria-current={isActive ? "page" : undefined}
            >
              {link.label}
            </a>
          ) : (
            <Link className={stateClass} key={link.label} href={link.href} aria-current={isActive ? "page" : undefined}>
              {link.label}
            </Link>
          );
        })}
      </nav>
    </header>
  );
}
