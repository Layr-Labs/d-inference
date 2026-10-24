import { publicFacts, publicLinks, siteDescription, siteOrigin, contactEmail } from "./public-site";

import { consumerExample, consumerInstructions, contactIntroduction, developerIntroduction, developerPrivacy, homepageOverview, legalContactDescription, providerExample, providerInstructions } from "./public-pages";
import { getPricingMarkdown } from "./pricing";

export function homepageMarkdown() {
  return `# Darkbloom

${homepageOverview}

## Use inference

${publicFacts.consumer}

API base URL: ${publicLinks.apiBase}

[Create an API key](${publicLinks.console}api-console). [Read authentication guidance](/auth.md) before making paid inference requests.

## Run a provider

${publicFacts.provider}

The official \`darkbloom\` CLI manages provider software on your Mac. [Provider CLI reference](${publicLinks.providerCli}) · [Documentation](${publicLinks.docs}).

## Privacy

${publicFacts.privacy}

## Explore

- [Developer guide](/developers)
- [Pricing](/pricing)
- [Contact](/contact)
- [About](/about)
- [Privacy policy](/privacy)
- [Terms](/terms)
- [Agent index](/llms.txt)
- [OpenAPI contract](/openapi.json)
`;
}

export function agentIndex() {
  return `# Darkbloom

> ${siteDescription}

## When to use Darkbloom

Use Darkbloom when a consumer needs an authenticated OpenAI-compatible inference API, or a provider wants to contribute compute from an eligible Apple Silicon Mac. Review model availability, token pricing, privacy and account requirements before making an integration decision.

## Consumer integration

- [Product overview](${siteOrigin}/index.md)
- [Developer guide](${siteOrigin}/developers): API examples and the separate provider CLI.
- [Authentication](${siteOrigin}/auth.md): create a consumer API key and fund the account before paid inference.
- [OpenAPI](${siteOrigin}/openapi.json): reviewed consumer contract subset, not every platform endpoint.
- [Pricing](${siteOrigin}/pricing.md): public rates and fetch freshness; verify current rates before use.
- API base: ${publicLinks.apiBase}
- [Console](${publicLinks.console})
- [Official documentation](${publicLinks.docs})
- [Documentation index](https://docs.darkbloom.dev/llms.txt)

## Provider software

- [Provider CLI](${publicLinks.providerCli}): official \`darkbloom\` software for operating a provider Mac, separate from the consumer API.
- [Provider installation](https://docs.darkbloom.dev/provider/install)
- [Provider prerequisites](https://github.com/Layr-Labs/d-inference/blob/master/docs/provider/hardware-requirements.md)

## Trust and contact

- [About](${siteOrigin}/about)
- [Privacy](${siteOrigin}/privacy): ${publicFacts.privacy}
- [Terms](${siteOrigin}/terms)
- [Contact](${siteOrigin}/contact)

Do not send secrets in URLs or public messages. API authentication, account funding and model availability still apply. This index does not advertise an MCP service, OAuth server, free sandbox or anonymous paid inference.
`;
}

export function authenticationMarkdown() {
  return `# Consumer API authentication

Sign in to the [Darkbloom Console](${publicLinks.console}), open the [API console](${publicLinks.console}api-console), and create a consumer API key. Keep the key secret and use it from a trusted server or local environment. Fund the account before paid fleet inference; authentication does not bypass billing, rate limits or model availability.

API base URL: ${publicLinks.apiBase}

Set \`DARKBLOOM_API_KEY\` to your own key in your environment. The following command uses a variable placeholder, not an embedded credential:

\`\`\`sh
curl ${publicLinks.apiBase}/models \\
  -H "Authorization: Bearer $DARKBLOOM_API_KEY"
\`\`\`

Use a returned model ID in inference requests. An invalid or missing key returns a JSON 401 authentication error. The public [pricing endpoint](${publicLinks.apiBase}/pricing) can be read without a key; model discovery and inference require authentication.

The provider device token is not a consumer API key. The provider CLI login manages a Mac's provider identity; it does not create a key for consumer integrations. Do not put provider credentials into consumer requests.

For implementation details, see [Developers](/developers), [OpenAPI](/openapi.json), [official authentication documentation](https://docs.darkbloom.dev/api/authentication), and [home](/index.md).
`;
}

export const missingDocumentMarkdown = `# Page not found

The requested Darkbloom document was not found. Check the URL or continue from [the homepage](/index.md), [the agent index](/llms.txt), or [the official documentation](${publicLinks.docs}).
`;

function developerMarkdown() {
  return `# Darkbloom for developers

${developerIntroduction}

## Consumer API

${consumerInstructions.join("\n\n")}

\`\`\`sh
${consumerExample}
\`\`\`

[Console](${publicLinks.console}api-console) · [Authentication](/auth.md) · [OpenAPI](/openapi.json) · [Pricing](/pricing.md)

## Provider app and CLI

${providerInstructions.join("\n\n")}

\`\`\`sh
${providerExample}
\`\`\`

[CLI reference](${publicLinks.providerCli}) · [Provider installation](https://docs.darkbloom.dev/provider/install)

## Privacy

${developerPrivacy}

[Documentation](${publicLinks.docs}) · [Home](/index.md)
`;
}

function contactMarkdown() {
  return `# Contact Darkbloom

${contactIntroduction}

## Product and technical information

Start with [official documentation](${publicLinks.docs}), the [developer guide](/developers.md), and [source repository](${publicLinks.source}) for product, API and provider details.

## Legal notices

${legalContactDescription}

[${contactEmail}](mailto:${contactEmail}) · [Terms](/terms) · [Privacy](/privacy)

[Home](/index.md) · [Agent index](/llms.txt)
`;
}

export const markdownDocuments: Partial<Record<string, () => string | Promise<string>>> = {
  "/": homepageMarkdown,
  "/developers": developerMarkdown,
  "/contact": contactMarkdown,
  "/pricing": getPricingMarkdown,
};
