import type { Metadata } from "next";
import { PublicPage } from "../../components/PublicPage";
import { contactIntroduction, legalContactDescription } from "../../content/public-pages";
import { contactEmail, publicLinks } from "../../content/public-site";

export const metadata: Metadata = { title: "Contact", description: contactIntroduction, alternates: { canonical: "/contact", types: { "text/markdown": "/contact.md" } } };

export default function ContactPage() {
  return <PublicPage title="Contact Darkbloom" introduction={contactIntroduction}>
    <section><h2>Using Darkbloom</h2>
      <p>For API integration and provider setup, start with the <a href={publicLinks.docs}>official documentation</a> and our <a href="/developers">developer guide</a>. Manage API keys, billing and linked provider Macs in the <a href={publicLinks.console}>Console</a>.</p>
      <p>For public product updates and community information, follow <a href={publicLinks.x}>Darkbloom on X</a> or <a href={publicLinks.linkedIn}>LinkedIn</a>. The <a href={publicLinks.source}>official GitHub repository</a> contains provider source and documentation. Keep API keys and private account information out of public posts.</p>
    </section>
    <section><h2>Legal notices</h2><p>{legalContactDescription}</p>
      <p><a href={`mailto:${contactEmail}`}>{contactEmail}</a></p>
      <p>Read the <a href="/terms">Terms of Service</a> and <a href="/privacy">Privacy Policy</a> for the terms that govern your use of Darkbloom and how information is handled.</p>
    </section>
  </PublicPage>;
}
