// Shared public facts for HTML, Markdown and discovery. Keep service behavior
// consistent with the platform-owned API and published privacy policy.
export const siteOrigin = "https://darkbloom.ai";
export const publicPagePaths = ["/", "/about", "/pricing", "/privacy", "/terms"] as const;
export const siteDescription =
  "Darkbloom is a decentralized private inference network powered by Apple Silicon Macs. Consumers use an OpenAI-compatible API; providers contribute compute through the Darkbloom app and CLI.";

export const publicFacts = {
  consumer: "Consumers send inference requests through Darkbloom’s authenticated, OpenAI-compatible API. Model availability and pricing depend on the network and the selected model.",
  provider: "Providers run Darkbloom software on Apple Silicon Macs to contribute inference compute. The provider app and CLI operate the Mac; they are separate from the consumer API.",
  privacy: "Requests are encrypted hop by hop. The coordinator decrypts requests in confidential-VM memory for routing and billing, does not log or retain prompt content, and re-encrypts each request to the provider’s attested key. The provider is the plaintext endpoint; this is not end-to-end encryption between consumer and provider.",
} as const;

export const publicLinks = {
  docs: "https://docs.darkbloom.dev/introduction",
  console: "https://console.darkbloom.dev/",
  apiBase: "https://api.darkbloom.dev/v1",
  providerCli: "https://github.com/Layr-Labs/d-inference/blob/master/docs/provider/cli-reference.md",
  source: "https://github.com/Layr-Labs/d-inference",
  operator: "https://www.eigenlabs.org/",
  x: "https://x.com/darkbloomai",
  linkedIn: "https://www.linkedin.com/showcase/darkbloom/",
} as const;

// Published legal contact, not an unverified support inbox.
export const contactEmail = "darkbloomnotices@eigenlabs.org";

export const publicStructuredData = {
  "@context": "https://schema.org",
  "@graph": [
    {
      "@type": "Organization",
      "@id": `${siteOrigin}/#operator`,
      name: "Eigen Labs, Inc.",
      url: publicLinks.operator,
      contactPoint: {
        "@type": "ContactPoint",
        contactType: "legal notices",
        email: contactEmail,
      },
    },
    {
      "@type": "WebSite",
      "@id": `${siteOrigin}/#website`,
      name: "Darkbloom",
      url: siteOrigin,
      description: siteDescription,
      publisher: { "@id": `${siteOrigin}/#operator` },
    },
    {
      "@type": "SoftwareApplication",
      "@id": `${siteOrigin}/#service`,
      name: "Darkbloom",
      url: siteOrigin,
      applicationCategory: "DeveloperApplication",
      operatingSystem: "Web, macOS",
      description: siteDescription,
      publisher: { "@id": `${siteOrigin}/#operator` },
      sameAs: [publicLinks.source, publicLinks.x, publicLinks.linkedIn],
    },
  ],
} as const;
