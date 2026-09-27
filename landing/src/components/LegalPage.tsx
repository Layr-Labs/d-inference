"use client";

import Link from "next/link";
import { useLayoutEffect } from "react";
import { SiteNav } from "./SiteNav";
import { PageWithFooter } from "./Footer";
import legalContent from "../content/legal-content.json";

type InlineNode = {
  type: "text" | "strong" | "link";
  text: string;
  href?: string;
};

type ParagraphBlock = {
  type: "paragraph";
  anchor: string;
  inline: InlineNode[];
};

type ListBlock = {
  type: "list";
  anchor: string;
  items: Array<{ anchor: string; inline: InlineNode[] }>;
};

type LegalSection = {
  number: string;
  title: string;
  heading: string;
  anchor: string;
  blocks: Array<ParagraphBlock | ListBlock>;
};

type LegalDocument = {
  slug: "terms" | "privacy";
  title: string;
  anchor: string;
  updatedLabel: string;
  leads: ParagraphBlock[];
  sections: LegalSection[];
  source: { url: string };
};

function Inline({ nodes }: { nodes: InlineNode[] }) {
  return nodes.map((node, index) => {
    const key = `${node.type}-${index}-${node.text.slice(0, 12)}`;
    if (node.type === "strong") return <strong key={key}>{node.text}</strong>;
    if (node.type === "link" && node.href) return <a key={key} href={node.href}>{node.text}</a>;
    return <span key={key}>{node.text}</span>;
  });
}

function Block({ block }: { block: ParagraphBlock | ListBlock }) {
  if (block.type === "list") {
    return (
      <ul id={block.anchor}>
        {block.items.map((item) => <li id={item.anchor} key={item.anchor}><Inline nodes={item.inline} /></li>)}
      </ul>
    );
  }
  return <p id={block.anchor}><Inline nodes={block.inline} /></p>;
}

export function LegalPage({ kind }: { kind: "terms" | "privacy" }) {
  const document = legalContent.documents[kind] as LegalDocument;
  useLayoutEffect(() => {
    const root = documentElement();
    root.style.scrollBehavior = "auto";
    window.scrollTo({ top: 0, behavior: "instant" });
    const frame = window.requestAnimationFrame(() => root.style.removeProperty("scroll-behavior"));
    return () => {
      window.cancelAnimationFrame(frame);
      root.style.removeProperty("scroll-behavior");
    };
  }, [kind]);

  return (
    <PageWithFooter className="blue-page legal-page">
      <SiteNav blue />
      <div className="legal-shell">
        <aside className="legal-switcher" aria-label="Legal documents">
          <Link className={kind === "terms" ? "is-current" : ""} href="/terms">Terms of service</Link>
          <Link className={kind === "privacy" ? "is-current" : ""} href="/privacy">Privacy policy</Link>
        </aside>
        <details className="legal-mobile-index">
          <summary>On this page</summary>
          <nav aria-label={`${document.title} sections`}>
            {document.sections.map((section) => <a key={section.anchor} href={`#${section.anchor}`}>{section.heading}</a>)}
          </nav>
        </details>
        <nav className="legal-index" aria-label={`${document.title} sections`}>
          <ol>
            {document.sections.map((section) => (
              <li key={section.anchor}><a href={`#${section.anchor}`}>{section.title}</a></li>
            ))}
          </ol>
        </nav>
        <article className="legal-document">
          <header>
            <h1 className="sr-only" id={document.anchor}>{document.title}</h1>
            <p>{document.updatedLabel}</p>
          </header>
          <div className="legal-leads">
            {document.leads.map((block) => <Block key={block.anchor} block={block} />)}
          </div>
          {document.sections.map((section) => (
            <section id={section.anchor} key={section.anchor}>
              <h2>{section.heading}</h2>
              {section.blocks.map((block) => <Block key={block.anchor} block={block} />)}
            </section>
          ))}
        </article>
      </div>
    </PageWithFooter>
  );
}

function documentElement() {
  return window.document.documentElement;
}
