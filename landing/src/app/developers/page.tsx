import type { Metadata } from "next";
import { PublicPage } from "../../components/PublicPage";
import { consumerExample, consumerInstructions, developerIntroduction, developerPrivacy, providerExample, providerInstructions } from "../../content/public-pages";
import { publicLinks } from "../../content/public-site";

export const metadata: Metadata = { title: "Developers", description: developerIntroduction, alternates: { canonical: "/developers", types: { "text/markdown": "/developers.md" } } };

export default function DevelopersPage() {
  return <PublicPage title="Build with Darkbloom" introduction={developerIntroduction}>
    <section><h2>Consumer API</h2>
      {consumerInstructions.map(text => <p key={text}>{text}</p>)}
      <p><a href="https://console.darkbloom.dev/api-console">Create an API key</a> · <a href="https://docs.darkbloom.dev/quickstart-consumer">Consumer quickstart</a> · <a href="/auth.md">Authentication guide</a></p>
      <pre><code>{consumerExample}</code></pre>
      <p>The example reads available models. Set DARKBLOOM_API_KEY in your environment; never commit it or expose it in browser code. Inference requests consume account funds and remain subject to authentication, billing and rate limits.</p>
      <p><a href="/openapi.json">Download the OpenAPI contract</a> · <a href="https://docs.darkbloom.dev/api/chat-completions">Chat API documentation</a> · <a href="/pricing">Public pricing</a></p>
    </section>
    <section><h2>Provider app and CLI</h2>
      {providerInstructions.map(text => <p key={text}>{text}</p>)}
      <p><a href="https://docs.darkbloom.dev/provider/install">Official installation guide</a> · <a href="https://github.com/Layr-Labs/d-inference/blob/master/docs/provider/hardware-requirements.md">Current provider requirements</a> · <a href={publicLinks.providerCli}>CLI reference and source</a></p>
      <pre><code>{providerExample}</code></pre>
    </section>
    <section><h2>Privacy and trust</h2><p>{developerPrivacy}</p><p><a href="/privacy">Privacy policy</a> · <a href="https://github.com/Layr-Labs/d-inference/blob/master/docs/architecture/security/encryption.md">Encryption model</a> · <a href="/contact">Contact and official channels</a></p></section>
  </PublicPage>;
}
