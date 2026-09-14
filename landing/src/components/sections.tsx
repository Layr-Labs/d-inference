import {
  CONSOLE_URL,
  INSTALL_COMMAND,
  PAPER_URL,
  REPO_URL,
} from "../lib/links";
import { Arrow, FeatureIcon, SectionLabel } from "./ui";
import { NetworkArt } from "./network-art";
import { CodeExample } from "./code-example";
import { CopyButton } from "./copy-button";
import { EarningsCalculator } from "./earnings-calculator";
import { Pricing } from "./pricing";

export function Hero() {
  return (
    <section className="hero container" data-section="hero">
      <div className="hero-copy">
        <a className="alpha-badge" href={`${CONSOLE_URL}/earn`}>
          <span className="status-dot" />
          Public alpha is open <Arrow />
        </a>
        <h1>
          Private inference.
          <br />
          <em>Open possibilities.</em>
        </h1>
        <p className="hero-description">
          Open models. Verified Apple Silicon. Your familiar API.{" "}
          <br className="desktop-break" />A private inference network, powered
          by the Macs around us.
        </p>
        <div className="hero-actions">
          <a href={CONSOLE_URL} className="button">
            Start building <Arrow diagonal />
          </a>
          <a href="#nodes" className="button button-outline">
            Earn with your Mac <Arrow />
          </a>
        </div>
      </div>
      <div className="network-showcase">
        <div className="showcase-copy">
          <span className="eyebrow">A NETWORK WITH A DIFFERENT FOUNDATION</span>
          <h2>
            Extraordinary compute.
            <br />
            Already on your desk.
          </h2>
          <a href={PAPER_URL} className="text-link">
            Meet Darkbloom <Arrow diagonal />
          </a>
        </div>
        <NetworkArt />
        <div className="showcase-footer">
          <span>Built by Eigen Labs</span>
          <span>Distributed by design.</span>
        </div>
      </div>
    </section>
  );
}

export function NetworkSection() {
  const features = [
    {
      type: "chip" as const,
      title: "Everyday hardware.\nExtraordinary potential.",
      body: "Apple Silicon pairs unified memory with efficient compute. Darkbloom connects that untapped capacity into a shared inference network.",
    },
    {
      type: "lock" as const,
      title: "Private by design.",
      body: "Encrypted requests, verified hardware, and a hardened runtime work together to protect inference from node operators.",
    },
    {
      type: "code" as const,
      title: "An API you already know.",
      body: "Use your existing OpenAI SDK with a new base URL. Access open models and streaming responses without rebuilding your application.",
    },
  ];
  return (
    <section id="why" className="section container" data-section="why">
      <div className="section-heading">
        <div>
          <SectionLabel>THE NETWORK</SectionLabel>
          <h2>
            Less infrastructure.
            <br />
            <em>More possibility.</em>
          </h2>
        </div>
        <p>
          The next chapter of AI doesn’t have to start with another data center.
          It can start with the Mac on your desk.
        </p>
      </div>
      <div className="feature-grid">
        {features.map((feature) => (
          <article className="feature-card" key={feature.type}>
            <div className="feature-top">
              <FeatureIcon type={feature.type} />
            </div>
            <h3>{feature.title}</h3>
            <p>{feature.body}</p>
          </article>
        ))}
      </div>
    </section>
  );
}

export function PrivacySection() {
  return (
    <section id="privacy" className="privacy-section" data-section="privacy">
      <div className="container">
        <div className="section-heading">
          <div>
            <SectionLabel>PRIVACY, BUILT IN</SectionLabel>
            <h2>
              Your next big idea.
              <br />
              <em>Kept close.</em>
            </h2>
          </div>
          <p>
            Trust should be something you can verify. Darkbloom combines
            encrypted transport with hardware-backed identity and runtime
            protection.
          </p>
        </div>
        <div className="privacy-grid">
          <div className="privacy-diagram">
            <div className="diagram-header">
              <span className="small-label">THE REQUEST PATH</span>
              <span>↓</span>
            </div>
            <div className="flow-node">
              <FeatureIcon type="code" />
              <div>
                <strong>Your application</strong>
                <span>OpenAI-compatible request over HTTPS</span>
              </div>
              <span className="flow-step">01</span>
            </div>
            <div className="flow-connector">
              <span />
              TLS
            </div>
            <div className="flow-node">
              <FeatureIcon type="lock" />
              <div>
                <strong>Darkbloom coordinator</strong>
                <span>Routing & billing in confidential-VM memory</span>
              </div>
              <span className="flow-step">02</span>
            </div>
            <div className="flow-connector">
              <span />
              NaCl Box encryption
            </div>
            <div className="flow-node">
              <FeatureIcon type="chip" />
              <div>
                <strong>Verified Apple Silicon</strong>
                <span>Decrypted for inference in a protected runtime</span>
              </div>
              <span className="flow-step">03</span>
            </div>
            <p>
              Prompt content is not logged or retained by the coordinator. The
              provider is the plaintext endpoint.
            </p>
          </div>
          <div className="privacy-features">
            <article>
              <span>01</span>
              <div>
                <h3>Encrypted, hop by hop</h3>
                <p>
                  Requests travel over encrypted connections. The coordinator
                  processes content in memory, then re-encrypts it to the
                  provider’s attested key.
                </p>
              </div>
            </article>
            <article>
              <span>02</span>
              <div>
                <h3>Hardware you can verify</h3>
                <p>
                  Secure Enclave signatures and Apple device attestation
                  establish the identity and security state of the Mac serving
                  your request.
                </p>
              </div>
            </article>
            <article>
              <span>03</span>
              <div>
                <h3>A protected inference runtime</h3>
                <p>
                  Code signing, hardened runtime, and system security checks
                  restrict debugging and unauthorized access to the inference
                  process.
                </p>
              </div>
            </article>
            <a
              className="text-link"
              href={`${REPO_URL}/blob/master/docs/architecture/security/encryption.md`}
            >
              Explore the security model <Arrow diagonal />
            </a>
          </div>
        </div>
      </div>
    </section>
  );
}

export function DeveloperSection() {
  return (
    <section
      id="api"
      className="section container developer-section"
      data-section="api"
    >
      <div className="developer-copy">
        <SectionLabel>MADE FOR DEVELOPERS</SectionLabel>
        <h2>
          Familiar tools.
          <br />
          <em>A different cloud.</em>
        </h2>
        <p className="section-description">
          Your tools, your SDKs, your workflow. Connect to Darkbloom with the
          OpenAI client you already know.
        </p>
        <div className="developer-features">
          <span>
            <span>↳</span> OpenAI-compatible chat completions
          </span>
          <span>
            <span>↳</span> Stream responses as they arrive
          </span>
          <span>
            <span>↳</span> Open models. Pay per token.
          </span>
        </div>
        <a href={CONSOLE_URL} className="button">
          Get your API key <Arrow diagonal />
        </a>
        <a
          href={`${REPO_URL}/blob/master/docs/consumer/quickstart.md`}
          className="text-link docs-link"
        >
          Read the quickstart <Arrow diagonal />
        </a>
      </div>
      <CodeExample />
    </section>
  );
}

export function PricingSection() {
  return (
    <section
      id="pricing"
      className="section container pricing-section"
      data-section="pricing"
    >
      <div className="section-heading">
        <div>
          <SectionLabel>PAY PER TOKEN</SectionLabel>
          <h2>
            Open models.
            <br />
            <em>Clear pricing.</em>
          </h2>
        </div>
        <p>
          Pay for the tokens you use. No subscription, no minimum. Put
          efficient, shared compute behind your next idea.
        </p>
      </div>
      <Pricing />
      <div className="pricing-bottom">
        <span>Prices in USD per million tokens.</span>
        <a className="text-link" href={`${CONSOLE_URL}/models`}>
          Explore the model catalog <Arrow diagonal />
        </a>
      </div>
    </section>
  );
}

export function EarnSection() {
  return (
    <section id="nodes" className="earn-section" data-section="earn">
      <div className="container earn-grid">
        <div className="earn-copy">
          <SectionLabel>FOR MAC OWNERS</SectionLabel>
          <h2>
            Your Mac can
            <br />
            <em>do more.</em>
          </h2>
          <p className="section-description">
            Turn spare Apple Silicon capacity into useful work. Join the
            network, serve inference, and earn from the jobs your Mac completes.
          </p>
          <div className="alpha-note">
            <span className="status-dot" />
            <span>
              During public alpha, operators keep{" "}
              <strong>100% of inference revenue.</strong>
            </span>
          </div>
          <ol className="provider-steps">
            <li>
              <span>01</span>
              <div>
                <strong>Install the provider</strong>
                <p>
                  Start with an Apple Silicon Mac and at least 48 GB of unified
                  memory.
                </p>
              </div>
            </li>
            <li>
              <span>02</span>
              <div>
                <strong>Connect & verify</strong>
                <p>
                  Link your account and complete device enrollment and hardware
                  checks.
                </p>
              </div>
            </li>
            <li>
              <span>03</span>
              <div>
                <strong>Make your compute count</strong>
                <p>
                  Run the provider when you’re available. Earnings depend on
                  network demand.
                </p>
              </div>
            </li>
          </ol>
          <div className="install-command">
            <code>{INSTALL_COMMAND}</code>
            <CopyButton
              text={INSTALL_COMMAND}
              label="Copy provider install command"
            />
          </div>
          <a
            className="text-link"
            href={`${REPO_URL}/blob/master/docs/provider/quickstart.md`}
          >
            Read the provider guide <Arrow diagonal />
          </a>
        </div>
        <EarningsCalculator />
      </div>
    </section>
  );
}

const questions = [
  {
    question: "What is Darkbloom?",
    answer:
      "Darkbloom is a private inference network that connects developers to open AI models running on verified Apple Silicon Macs. It’s built by Eigen Labs and uses a coordinator to route requests, verify providers, and handle billing.",
  },
  {
    question: "Can I use my existing OpenAI client?",
    answer:
      "Yes. Set your client’s base URL to https://api.darkbloom.dev/v1, use a Darkbloom API key, and choose a model from the catalog. The API supports chat completions and streaming. Model availability and supported capabilities vary.",
  },
  {
    question: "Who can access my prompts?",
    answer:
      "The coordinator processes request content in confidential-VM memory for routing and billing, without logging or retaining prompts, and re-encrypts it to the provider’s attested key. The provider decrypts content for inference. Hardware verification and runtime protections are designed to keep node operators from inspecting the process. Read the security model for the full trust assumptions.",
  },
  {
    question: "What do I need to run a node?",
    answer:
      "An Apple Silicon Mac with at least 48 GB of unified memory, a reliable internet connection, and a supported macOS version. You’ll install the provider, link your account, and complete device enrollment and verification. Model eligibility also depends on your available memory.",
  },
  {
    question: "Are the earnings estimates guaranteed?",
    answer:
      "No. The calculator estimates gross revenue from memory bandwidth, model characteristics, reference output-token prices, and the duty cycle you select. Actual earnings depend on demand, availability, performance, and costs. Electricity, fees, and taxes are not deducted.",
  },
];

export function FAQSection() {
  return (
    <section className="section container faq-section" data-section="faq">
      <div>
        <SectionLabel>FAQ</SectionLabel>
        <h2>Good to know.</h2>
        <a className="text-link" href={`${REPO_URL}/tree/master/docs`}>
          Explore the documentation <Arrow diagonal />
        </a>
      </div>
      <div className="faq-list">
        {questions.map(({ question, answer }) => (
          <details key={question}>
            <summary>
              {question}
              <span className="faq-plus" aria-hidden="true">
                +
              </span>
            </summary>
            <p>{answer}</p>
          </details>
        ))}
      </div>
    </section>
  );
}

export function FinalCTA() {
  return (
    <section className="final-cta container" data-section="get-started">
      <SectionLabel>BUILD WITH DARKBLOOM</SectionLabel>
      <h2>
        Your next idea
        <br />
        <em>starts here.</em>
      </h2>
      <div>
        <a href={CONSOLE_URL} className="button">
          Start building <Arrow diagonal />
        </a>
        <a href={`${CONSOLE_URL}/earn`} className="button button-outline">
          Join the network <Arrow />
        </a>
      </div>
    </section>
  );
}
