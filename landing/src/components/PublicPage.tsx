import type { ReactNode } from "react";
import { PageWithFooter } from "./Footer";
import { SiteNav } from "./SiteNav";
import "../app/public-pages.css";

export function PublicPage({ title, introduction, children }: { title: string; introduction: string; children: ReactNode }) {
  return <PageWithFooter className="blue-page public-page">
    <SiteNav blue />
    <article className="public-document">
      <header><h1>{title}</h1><p>{introduction}</p></header>
      {children}
    </article>
  </PageWithFooter>;
}
