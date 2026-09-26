"use client";

import { useEffect, useLayoutEffect, useRef, useState } from "react";
import type { CSSProperties, ReactNode } from "react";
import { PageWithFooter } from "./Footer";
import { SiteNav } from "./SiteNav";

type Audience = "developers" | "owners";

type LiveModel = {
  id: string;
  name: string;
  architecture: string;
  description: string;
  contextLength: number | null;
  minRamGB: number | null;
  sizeGB: number | null;
  inputPriceMicro: number;
  outputPriceMicro: number;
  status: string;
};

type AboutData = {
  available: boolean;
  stats: { gpuCores: number | null; cpuCores: number | null; memoryGB: number | null } | null;
  models: LiveModel[];
  degraded?: boolean;
};

const PRICING_ROWS = [
  { name: "GPT-OSS 20B", specification: "MoE · 128K context", input: "$0.0145", output: "$0.07", typical: "$0.14", savings: "50% lower" },
  { name: "Gemma 4 26B", specification: "128K context", input: "$0.05", output: "$0.25", typical: "$0.90", savings: "50% lower" },
  { name: "Qwen 3.6 35B A3B", specification: "Qwen3.5 MoE VLM with inline MTP · 256K context", input: "$0.08", output: "$0.75", typical: "$1.55", savings: "50% lower" },
  { name: "Gemma 4 26B", specification: "MoE · 128K context", input: "$0.05", output: "$0.75", typical: null, savings: null },
  { name: "Gemma 4 26B 8-bit rollback", specification: "128K context", input: "$0.05", output: "$0.25", typical: null, savings: null },
] as const;

const AUDIENCE_COPY: Record<Audience, string> = {
  developers: "Swap the base URL, keep your existing OpenAI client. Requests are encrypted before they leave your app.",
  owners: "Run a provider on hardware you already have. Darkbloom matches your Mac to demand it can actually handle.",
};

const ABOUT_PRIVACY_DISCLAIMER = "*Privacy guarantees apply to direct requests. Requests routed through third-party services before reaching Darkbloom are subject to those services' own privacy policies.";

function formatNumber(value: number | null | undefined, suffix = "") {
  return value == null ? "—" : `${new Intl.NumberFormat("en-US", { maximumFractionDigits: 0 }).format(value)}${suffix}`;
}

function clamp01(value: number) {
  return Math.min(1, Math.max(0, value));
}

function easeInOutCubic(value: number) {
  return value < 0.5 ? 4 * value * value * value : 1 - Math.pow(-2 * value + 2, 3) / 2;
}

function Reveal({ children, delay = 0, className = "" }: { children: ReactNode; delay?: number; className?: string }) {
  return <div className={`about-reveal ${className}`} style={{ "--reveal-delay": `${delay}ms` } as CSSProperties}>{children}</div>;
}

export function AboutExperience() {
  const transitionSurface = useRef<HTMLDivElement>(null);
  const transitionSection = useRef<HTMLDivElement>(null);
  const [audience, setAudience] = useState<Audience>("owners");
  const [liveData, setLiveData] = useState<AboutData | null>(null);

  useLayoutEffect(() => {
    if (window.location.hash) return;
    const previousRestoration = window.history.scrollRestoration;
    window.history.scrollRestoration = "manual";
    window.scrollTo({ top: 0, left: 0, behavior: "instant" });
    return () => {
      window.history.scrollRestoration = previousRestoration;
    };
  }, []);

  useEffect(() => {
    const root = document.documentElement;
    const body = document.body;
    const previousRootColor = root.style.backgroundColor;
    const previousBodyColor = body.style.backgroundColor;
    const paintOverscrollColor = () => {
      const maxScroll = Math.max(0, root.scrollHeight - window.innerHeight);
      const color = window.scrollY >= maxScroll - 8 ? "#0b41ff" : "#000000";
      root.style.backgroundColor = color;
      body.style.backgroundColor = color;
    };
    paintOverscrollColor();
    window.addEventListener("scroll", paintOverscrollColor, { passive: true });
    window.addEventListener("resize", paintOverscrollColor);
    return () => {
      window.removeEventListener("scroll", paintOverscrollColor);
      window.removeEventListener("resize", paintOverscrollColor);
      root.style.backgroundColor = previousRootColor;
      body.style.backgroundColor = previousBodyColor;
    };
  }, []);

  useEffect(() => {
    const controller = new AbortController();
    void fetch("/api/about", { cache: "no-store", signal: controller.signal })
      .then(async (response) => {
        if (!response.ok) throw new Error("About data unavailable");
        return response.json() as Promise<AboutData>;
      })
      .then(setLiveData)
      .catch(() => setLiveData({ available: false, stats: null, models: [] }));
    return () => controller.abort();
  }, []);

  useEffect(() => {
    let frame = 0;
    const paint = () => {
      frame = 0;
      const surface = transitionSurface.current;
      const transition = transitionSection.current;
      if (!surface || !transition) return;

      const viewport = window.innerHeight;
      const progress = clamp01((viewport - transition.getBoundingClientRect().top) / Math.max(1, viewport));
      const reverse = 1 - progress;
      const navyMix = easeInOutCubic(clamp01((reverse - 0.02) / 0.72));
      const blackMix = easeInOutCubic(clamp01((reverse - 0.08) / 0.9));
      const blue = [11, 65, 255];
      const navy = [6, 27, 88];
      const color = blue.map((channel, index) => Math.round((channel + (navy[index] - channel) * navyMix) * (1 - blackMix)));
      const heroOpacity = 1 - easeInOutCubic(clamp01(progress / 0.42));

      surface.style.backgroundColor = `rgb(${color.join(" ")})`;
      surface.style.setProperty("--about-fade-progress", progress.toFixed(5));
      surface.style.setProperty("--about-hero-copy-opacity", heroOpacity.toFixed(5));
      surface.style.setProperty("--about-hero-media-opacity", heroOpacity.toFixed(5));
    };
    const queuePaint = () => {
      if (!frame) frame = requestAnimationFrame(paint);
    };

    paint();
    window.addEventListener("scroll", queuePaint, { passive: true });
    window.addEventListener("resize", queuePaint);
    return () => {
      if (frame) cancelAnimationFrame(frame);
      window.removeEventListener("scroll", queuePaint);
      window.removeEventListener("resize", queuePaint);
    };
  }, []);

  useEffect(() => {
    const nodes = [...document.querySelectorAll<HTMLElement>(".about-reveal")];
    if (window.matchMedia("(prefers-reduced-motion: reduce)").matches) {
      nodes.forEach((node) => node.classList.add("is-visible"));
      return;
    }
    const observer = new IntersectionObserver((entries) => {
      for (const entry of entries) {
        if (!entry.isIntersecting) continue;
        entry.target.classList.add("is-visible");
        observer.unobserve(entry.target);
      }
    }, { rootMargin: "0px 0px -12%", threshold: 0.08 });
    nodes.forEach((node) => observer.observe(node));
    return () => observer.disconnect();
  }, []);

  return (
    <PageWithFooter className="blue-page about-page about-r6" footerDisclaimer={ABOUT_PRIVACY_DISCLAIMER}>
      <SiteNav />
      <div className="about-r6-transition-surface" ref={transitionSurface}>
        <section className="about-r6-hero" aria-labelledby="about-r6-title">
        <div className="about-r6-hero-copy">
          <p className="about-r6-kicker about-r6-kicker--hero">What is Darkbloom</p>
          <h1 id="about-r6-title">A new topology for private inference.</h1>
          <p className="about-r6-intro">Darkbloom routes encrypted requests to verified Apple Silicon hardware, at roughly half the cost of typical API providers. Prompts stay hidden from operators. Mac owners earn from compute they already own.</p>
          <div className="about-audience" role="tablist" aria-label="Choose your view">
            <button type="button" role="tab" aria-selected={audience === "owners"} onClick={() => setAudience("owners")}>For Mac Owners</button>
            <button type="button" role="tab" aria-selected={audience === "developers"} onClick={() => setAudience("developers")}>For Developers</button>
          </div>
          <div className="about-audience-copy" key={audience}>
            <p>{AUDIENCE_COPY[audience]}</p>
          </div>
          <a
            className="about-hero-cta"
            href={audience === "owners" ? "https://console.darkbloom.dev/" : "https://openrouter.ai/provider/darkbloom"}
            target="_blank"
            rel="noreferrer"
          >
            Join the grid ↗
          </a>
        </div>
        <div className="about-r6-chip" aria-label="Animated private inference chip">
          <video autoPlay loop muted playsInline preload="metadata" width={643} height={558}>
            <source src="/media/about-chip.mp4" type="video/mp4" />
          </video>
        </div>
        </section>

        <div className="about-r6-fade" ref={transitionSection}>
          <section className="about-market" aria-labelledby="about-market-title">
            <Reveal><p className="about-r6-kicker">Why does it cost less</p></Reveal>
            <Reveal delay={70}><h2 id="about-market-title">Darkbloom turns idle capacity into a private inference market</h2></Reveal>
            <Reveal delay={140}><p className="about-r6-section-copy">Typical inference passes through clouds, resellers, and API layers, each adding margin. Darkbloom routes requests to idle Apple Silicon instead - hardware its owners already paid for, where the marginal cost is mostly electricity. Pay per token, with no subscription or minimum.</p></Reveal>
          </section>
        </div>

        <div className="about-r6-blue">

        <section className="about-pricing" id="pricing" aria-labelledby="about-pricing-title">
          <Reveal className="about-pricing-card">
            <h2 id="about-pricing-title">Decentralized Inference Pricing</h2>
            <div className="about-pricing-scroll">
              <table>
                <thead><tr><th>Model &amp; Specification</th><th>Input (1M Tok)</th><th>Output (1M Tok)</th><th>Typical API</th><th>vs typical API</th></tr></thead>
                <tbody>
                  {PRICING_ROWS.map((row, index) => (
                    <tr key={`${row.name}-${index}`}>
                      <td><b>{row.name}</b><small>{row.specification}</small></td>
                      <td data-label="Input (1M Tok)">{row.input}</td>
                      <td data-label="Output (1M Tok)">{row.output}</td>
                      <td data-label="Typical API">{row.typical ? <s>{row.typical}</s> : "-"}</td>
                      <td data-label="vs typical API">{row.savings ? <span className="about-savings">{row.savings}</span> : "-"}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
            <div className="about-card-footer">
              <p>Prices per million tokens. Typical API means published list rates for comparable models from major API providers.</p>
              <a href="https://github.com/Layr-Labs/d-inference" target="_blank" rel="noreferrer">View full documentation ↗</a>
            </div>
          </Reveal>
        </section>

        <section className="about-privacy" id="privacy" aria-labelledby="about-privacy-title">
          <div className="about-privacy-copy">
            <Reveal><p className="about-r6-kicker">Why privacy matters*</p></Reveal>
            <Reveal delay={70}><h2 id="about-privacy-title">Sensitive information shouldn&apos;t run on untrusted hardware</h2></Reveal>
            <Reveal delay={140}><p className="about-r6-section-copy">Every prompt carries information you&apos;d never publish: personal reflections, customer conversations, source code, strategy. Darkbloom&apos;s privacy is more than a policy. The coordinator can route requests, the providers can serve them, but neither can get a usable view of the prompt.</p></Reveal>
            <Reveal delay={210}><a className="about-text-link" href="https://github.com/Layr-Labs/d-inference/blob/master/papers/dginf-private-inference.pdf" target="_blank" rel="noreferrer">Read the whitepaper ↗</a></Reveal>
          </div>
          <Reveal delay={80} className="about-flow-wrap">
            <div className="about-flow" role="img" aria-label="Encrypted requests flow from your app through Darkbloom to verified Macs and return as private results">
              <span className="about-flow-label about-flow-label--in">Encrypted request in</span>
              <div className="about-flow-app">
                <span className="about-flow-bars" aria-hidden><i /><i /></span>
                <b>Your App</b>
              </div>
              <i className="about-flow-line about-flow-line--elbow" aria-hidden />
              <div className="about-flow-core">
                {/* eslint-disable-next-line @next/next/no-img-element */}
                <img src="/media/about-flow-mark.svg" alt="" width={63} height={72} />
              </div>
              <i className="about-flow-line about-flow-line--out" aria-hidden />
              <div className="about-flow-provider about-flow-provider--studio"><b>Mac Studio</b><small>verified</small></div>
              <span className="about-flow-label about-flow-label--out">Private result out</span>
              <div className="about-flow-provider about-flow-provider--hub"><b>Verified Macs</b><small>serve inference</small></div>
              <div className="about-flow-provider about-flow-provider--macbook"><b>MacBook</b><small>verified</small></div>
              <ul className="about-flow-points">
                <li>Encrypted</li>
                <li>50% lower cost</li>
                <li>Private</li>
              </ul>
            </div>
          </Reveal>
        </section>

        <section className="about-operator" id="security" aria-labelledby="about-operator-title">
          <div className="about-operator-copy">
            <Reveal><p className="about-r6-kicker about-r6-kicker--lg">How privacy is ensured*</p></Reveal>
            <Reveal delay={70}><h2 id="about-operator-title">Operator blind by design</h2></Reveal>
            <Reveal delay={140}><p className="about-r6-section-copy">Darkbloom removes software paths an operator could use to observe inference data. Requests are encrypted, the OS is sealed, memory is isolated, and the process itself refuses inspection.</p></Reveal>
          </div>
          <Reveal delay={80} className="about-layers-wrap">
            <div className="about-layers" aria-label="Four layers protect inference data">
              <div className="about-layer about-layer--1">
                <div className="about-layer-head"><b>01 / E2E Encryption</b><small>encrypted before it leaves your device</small></div>
                <div className="about-layer about-layer--2">
                  <div className="about-layer-head"><b>02 / OS Integrity</b><small>SIP enforced · signed system volume · binary self-hash</small></div>
                  <div className="about-layer about-layer--3">
                    <div className="about-layer-head"><b>03 / Memory Isolation</b><small>Hypervisor.framework · Stage 2 page tables</small></div>
                    <div className="about-layer about-layer--4">
                      <div className="about-layer-head"><b>04 / Hardened Process</b><small>debugger blocked · no shell access</small></div>
                      <div className="about-layer-core">
                        <b>Your inference data</b>
                        <span>prompts · responses · model state</span>
                      </div>
                    </div>
                  </div>
                </div>
              </div>
            </div>
            <p className="about-layers-caption">operator is here, every path inward is eliminated</p>
          </Reveal>
        </section>

        <section className="about-hardware" id="compute" aria-labelledby="about-hardware-title">
          <div className="about-hardware-copy">
            <Reveal><p className="about-r6-kicker about-r6-kicker--lg">What powers the grid</p></Reveal>
            <Reveal delay={70}><h2 id="about-hardware-title">Decentralized inference on Apple Silicon mac hardware</h2></Reveal>
            <Reveal delay={140}><p className="about-r6-section-copy">The grid runs on fleet of consumer Macs, M1 through M5. High-memory machines powering a range of open-source models and the router assigns each request to the most capable available machine automatically.</p></Reveal>
          </div>
          <div className="about-hardware-stats" aria-live="polite">
            {[
              ["GPU Cores", "Apple Silicon", formatNumber(liveData?.stats?.gpuCores)],
              ["CPU Cores", "P + E cores", formatNumber(liveData?.stats?.cpuCores)],
              ["Unified Ram", null, formatNumber(liveData?.stats?.memoryGB, " GB")],
            ].map(([label, note, value], index) => (
              <Reveal delay={index * 95} className="about-hardware-stat" key={label}>
                <span>{label}</span>
                <span className="about-hardware-value">{note && <small>{note}</small>}{value}</span>
              </Reveal>
            ))}
          </div>
        </section>

        <section className="about-earn" id="earn" aria-labelledby="about-earn-title">
          <div className="about-earn-copy">
            <Reveal><p className="about-r6-kicker about-r6-kicker--lg">How much can providers earn</p></Reveal>
            <Reveal delay={70}><h2 id="about-earn-title">Earn from compute<br />you already own</h2></Reveal>
            <Reveal delay={140}><p className="about-r6-section-copy">Darkbloom pays you a base reward just for staying online, plus usage earnings on top every time your Mac serves a real inference request. Earnings scale based on your chip and memory - the more capable your machine, the more it can run.</p></Reveal>
          </div>
          <Reveal delay={80} className="about-calculator about-earnings-estimate">
            <div className="about-earnings-summary">
              <div className="about-earnings-total">
                <p className="about-earnings-label">Estimated monthly earning</p>
                <p className="about-earnings-amount">$204.89<small>/mo</small></p>
                <p className="about-earnings-annual">$2,458.64/yr at 60% duty cycle</p>
              </div>
              <dl className="about-earnings-specs">
                <div><dt>Mac model</dt><dd>MacBook Pro</dd></div>
                <div><dt>Chip family</dt><dd>M4 Max (16-core)</dd></div>
                <div><dt>Unified memory</dt><dd>128 GB</dd></div>
              </dl>
            </div>
            <p className="about-earnings-duty">This estimate assumes a 60% duty cycle - the share of time your Mac is actively producing output tokens. Actual earnings may vary.</p>
            <div className="about-earnings-catalog">
              <div className="about-earnings-catalog-head">
                <p>Models your Mac can run</p>
                <p>Models are ranked by estimated monthly earning at the selected duty cycle.</p>
              </div>
              <div className="about-model-list">
                <div>
                  <span className="about-model-details"><b>Qwen3.6 35B A3B <em>Best current estimate</em></b><small>Fits in your 128 GB (22 GB of model weights)</small></span>
                  <span className="about-model-earnings"><b>$204.89/mo</b></span>
                </div>
                <div>
                  <span className="about-model-details"><b>Gamma 4 26B A4B</b><small>Fits in your 128 GB (18 GB of model weights)</small></span>
                  <span className="about-model-earnings"><b>$182.40/mo</b></span>
                </div>
                <div>
                  <span className="about-model-details"><b>GPT-OSS 20B</b><small>Fits in your 128 GB (14 GB of model weights)</small></span>
                  <span className="about-model-earnings"><b>$144.15/mo</b></span>
                </div>
              </div>
            </div>
            <div className="about-earnings-footer">
              <p>This is a projection, not a promise. Usage earnings assume healthy, sustained network demand — live demand fluctuates and can run below this. The base reward requires an attested, healthy machine that stays online ≥90% of each settlement period, and is paid from a fixed monthly pool — an earnings floor while eligible, not a guarantee.</p>
              <a href="https://console.darkbloom.dev/earn" target="_blank" rel="noreferrer">Learn more ↗</a>
            </div>
          </Reveal>
        </section>
        </div>
      </div>
    </PageWithFooter>
  );
}
