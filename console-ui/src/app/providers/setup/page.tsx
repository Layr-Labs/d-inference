"use client";

import { useState } from "react";
import {
  Cpu,
  Monitor,
  Wifi,
  Shield,
  Terminal,
  Play,
  CheckCircle2,
  ChevronDown,
  Copy,
  Check,
} from "lucide-react";

function CopyableCommand({ command }: { command: string }) {
  const [copied, setCopied] = useState(false);

  return (
    <div className="relative group">
      <pre className="bg-bg-tertiary rounded-lg px-4 py-3 text-sm font-mono text-text-primary overflow-x-auto">
        <code>{command}</code>
      </pre>
      <button
        onClick={() => {
          navigator.clipboard.writeText(command);
          setCopied(true);
          setTimeout(() => setCopied(false), 2000);
        }}
        className="absolute top-2 right-2 p-1.5 rounded-md bg-bg-elevated/80 text-text-tertiary hover:text-text-secondary transition-colors opacity-0 group-hover:opacity-100"
      >
        {copied ? <Check size={14} /> : <Copy size={14} />}
      </button>
    </div>
  );
}

function FaqItem({ question, answer }: { question: string; answer: string }) {
  const [open, setOpen] = useState(false);

  return (
    <div className="border-b border-border-dim last:border-0">
      <button
        onClick={() => setOpen(!open)}
        className="w-full flex items-center justify-between py-4 text-left"
      >
        <span className="text-sm font-medium text-text-primary">{question}</span>
        <ChevronDown
          size={16}
          className={`text-text-tertiary transition-transform ${open ? "rotate-180" : ""}`}
        />
      </button>
      {open && (
        <p className="pb-4 text-sm text-text-secondary leading-relaxed">{answer}</p>
      )}
    </div>
  );
}

const STEPS = [
  {
    icon: Terminal,
    title: "Install the Provider CLI",
    description: "One command to download and install the Darkbloom provider on your Mac.",
    command: "curl -fsSL https://api.darkbloom.dev/install.sh | bash",
  },
  {
    icon: Shield,
    title: "Link Your Account",
    description: "Link this machine to your Darkbloom account. You'll get a code to enter on the web to verify ownership.",
    command: "darkbloom login",
  },
  {
    icon: Play,
    title: "Start the Provider",
    description: "Launch the provider. It will show an interactive picker to select models based on your hardware, download them, and start serving.",
    command: "darkbloom start",
  },
  {
    icon: CheckCircle2,
    title: "Check Status",
    description: "Verify your provider is online and serving. Hardware attestation via Secure Enclave happens automatically.",
    command: "darkbloom status",
  },
];

const REQUIREMENTS = [
  {
    icon: Cpu,
    title: "Apple Silicon Mac",
    description: "M1, M2, M3, or M4 series (any tier). GPU inference runs natively on the Neural Engine and GPU.",
  },
  {
    icon: Monitor,
    title: "macOS 14.0+",
    description: "Sonoma or later required for Secure Enclave attestation and hardware security features.",
  },
  {
    icon: Wifi,
    title: "Stable Internet",
    description: "Reliable connection with low latency. Inference requests are routed based on network quality.",
  },
  {
    icon: Shield,
    title: "16GB+ RAM",
    description: "Recommended minimum for serving 4-bit quantized models. 32GB+ enables larger models.",
  },
];

const FAQ = [
  {
    question: "How much can I earn as a provider?",
    answer: "Earnings depend on the models you serve, your hardware specs, and demand. Providers are paid per-token for inference jobs. Higher-trust providers (hardware attested) receive priority routing and higher scores.",
  },
  {
    question: "What models can I serve?",
    answer: "The interactive model picker shows all supported models that fit your hardware. Models include text models like Qwen3.5 27B, Gemma 4 26B, and MiniMax M2.5 239B. The provider downloads selected models automatically.",
  },
  {
    question: "What is hardware attestation?",
    answer: "Hardware attestation uses Apple's Secure Enclave to cryptographically prove your device's identity and security posture. This includes SIP status, Secure Boot, and system integrity. Attested providers receive higher trust scores and priority routing.",
  },
  {
    question: "Can I run the provider on a Mac mini / Mac Studio headless?",
    answer: "Yes. Configure power management to prevent sleep (pmset -c sleep 0 discsleep 0) and the provider daemon will run as a background service. Note that closing a MacBook lid will put it to sleep regardless of pmset settings.",
  },
  {
    question: "How does the idle timeout work?",
    answer: "The vllm-mlx backend process is automatically stopped after 1 hour of no inference requests to free GPU memory. When a new request arrives, the model is lazy-reloaded (10-30 second cold start). This is configurable via the provider config.",
  },
];

export default function ProviderSetupPage() {
  return (
    <div className="max-w-4xl mx-auto p-6 space-y-12">
      {/* Hero */}
      <div className="text-center py-8">
        <div className="inline-flex items-center gap-2 px-3 py-1.5 rounded-full bg-accent-amber/10 text-accent-amber text-xs font-medium mb-4">
          <span className="w-1.5 h-1.5 rounded-full bg-accent-amber animate-pulse" />
          Pilot Program
        </div>
        <h1 className="text-3xl font-bold text-text-primary tracking-tight mb-3">
          Become a Darkbloom Provider
        </h1>
        <p className="text-base text-text-secondary max-w-xl mx-auto leading-relaxed">
          Earn by serving AI inference from your Apple Silicon hardware.
          Your Mac becomes part of a decentralized, hardware-attested inference network.
        </p>
        <p className="text-xs text-text-tertiary max-w-md mx-auto mt-3 leading-relaxed">
          Darkbloom is an experimental research project in active development.
          Provider participation is part of our pilot program and the system may change as we iterate.
        </p>
      </div>

      {/* Requirements */}
      <div>
        <h2 className="text-lg font-semibold text-text-primary mb-4">Requirements</h2>
        <div className="grid grid-cols-2 gap-4">
          {REQUIREMENTS.map(({ icon: Icon, title, description }) => (
            <div key={title} className="rounded-xl bg-bg-secondary shadow-sm p-5">
              <div className="w-10 h-10 rounded-lg bg-accent-brand/10 flex items-center justify-center mb-3">
                <Icon size={20} className="text-accent-brand" />
              </div>
              <h3 className="text-sm font-semibold text-text-primary mb-1">{title}</h3>
              <p className="text-sm text-text-secondary leading-relaxed">{description}</p>
            </div>
          ))}
        </div>
      </div>

      {/* Step by step */}
      <div>
        <h2 className="text-lg font-semibold text-text-primary mb-6">Setup Guide</h2>
        <div className="space-y-6">
          {STEPS.map(({ icon: Icon, title, description, command }, i) => (
            <div key={title} className="flex gap-4">
              <div className="flex flex-col items-center">
                <div className="w-10 h-10 rounded-full bg-accent-brand/10 flex items-center justify-center shrink-0">
                  <span className="text-sm font-bold text-accent-brand">{i + 1}</span>
                </div>
                {i < STEPS.length - 1 && (
                  <div className="w-px flex-1 bg-border-dim mt-2" />
                )}
              </div>
              <div className="flex-1 pb-6">
                <div className="flex items-center gap-2 mb-1">
                  <Icon size={16} className="text-text-tertiary" />
                  <h3 className="text-sm font-semibold text-text-primary">{title}</h3>
                </div>
                <p className="text-sm text-text-secondary mb-3">{description}</p>
                <CopyableCommand command={command} />
              </div>
            </div>
          ))}
        </div>
      </div>

      {/* FAQ */}
      <div>
        <h2 className="text-lg font-semibold text-text-primary mb-4">Frequently Asked Questions</h2>
        <div className="rounded-xl bg-bg-secondary shadow-sm px-6">
          {FAQ.map(({ question, answer }) => (
            <FaqItem key={question} question={question} answer={answer} />
          ))}
        </div>
      </div>
    </div>
  );
}
