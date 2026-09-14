"use client";

import { useRef, useState } from "react";
import { CONSOLE_URL } from "../lib/links";
import { Arrow, Mark } from "./ui";

const links = [
  ["The network", "#why"],
  ["Privacy", "#privacy"],
  ["Developers", "#api"],
  ["Pricing", "#pricing"],
  ["Earn", "#nodes"],
];

export function Header() {
  const [open, setOpen] = useState(false);
  const toggle = useRef<HTMLButtonElement>(null);
  return (
    <header
      className="site-header"
      onKeyDown={(event) => {
        if (event.key === "Escape") {
          setOpen(false);
          toggle.current?.focus();
        }
      }}
    >
      <div className="header-inner">
        <a
          href="#"
          className="brand"
          aria-label="Darkbloom home"
          onClick={() => setOpen(false)}
        >
          <Mark />
          <span>darkbloom</span>
        </a>
        <nav className="desktop-nav" aria-label="Main navigation">
          {links.map(([label, href]) => (
            <a key={href} href={href}>
              {label}
            </a>
          ))}
        </nav>
        <a href={CONSOLE_URL} className="button button-small header-cta">
          Open console <Arrow diagonal />
        </a>
        <button
          ref={toggle}
          className="menu-toggle"
          aria-expanded={open}
          aria-controls="mobile-nav"
          aria-label={open ? "Close menu" : "Open menu"}
          onClick={() => setOpen(!open)}
        >
          <span className={open ? "menu-lines is-open" : "menu-lines"}>
            <i />
            <i />
          </span>
        </button>
      </div>
      <nav
        id="mobile-nav"
        className="mobile-nav"
        aria-label="Mobile navigation"
        hidden={!open}
      >
        {links.map(([label, href]) => (
          <a key={href} href={href} onClick={() => setOpen(false)}>
            {label}
            <Arrow />
          </a>
        ))}
        <a href={CONSOLE_URL} onClick={() => setOpen(false)}>
          Open console
          <Arrow diagonal />
        </a>
      </nav>
    </header>
  );
}
