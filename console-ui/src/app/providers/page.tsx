"use client";

import { useEffect, useState } from "react";
import { trackEvent } from "@/lib/google-analytics";
import { useAuth } from "@/hooks/useAuth";
import { useVerificationMode } from "@/lib/verification-mode";
import {
  ShieldCheck,
  Shield,
  Cpu,
  HardDrive,
  Lock,
  Fingerprint,
  Check,
  X,
  Loader2,
  ExternalLink,
  ChevronDown,
  Server,
  ArrowRight,
  Mail,
} from "lucide-react";
import Link from "next/link";

const ATTESTATION_API = "https://api.darkbloom.dev";

function maskSerial(serial: string): string {
  if (serial.length <= 6) return serial;
  return serial.slice(0, 4) + "\u2022".repeat(serial.length - 6) + serial.slice(-2);
}

interface Provider {
  provider_id: string;
  chip_name: string;
  hardware_model: string;
  serial_number: string;
  trust_level: string;
  status: string;
  memory_gb: number;
  gpu_cores: number;
  models: string[];
  secure_enclave: boolean;
  sip_enabled: boolean;
  secure_boot_enabled: boolean;
  authenticated_root_enabled: boolean;
  system_volume_hash: string;
  se_public_key: string;
  mdm_verified: boolean;
  acme_verified: boolean;
  mda_verified: boolean;
  mda_cert_chain_b64?: string[];
  mda_serial?: string;
  mda_udid?: string;
  mda_os_version?: string;
  mda_sepos_version?: string;
  wallet_address?: string;
}

function TrustBadge({ level, mdaVerified }: { level: string; mdaVerified: boolean }) {
  if (level === "hardware") {
    return (
      <span className="inline-flex items-center gap-1.5 px-2.5 py-1 rounded-full bg-accent-green/10 text-accent-green text-xs font-medium">
        <ShieldCheck size={12} />
        {mdaVerified ? "Apple-verified hardware" : "Hardware Verified"}
      </span>
    );
  }
  return (
    <span className="inline-flex items-center gap-1.5 px-2.5 py-1 rounded-full bg-bg-tertiary text-text-tertiary text-xs font-medium">
      <Shield size={12} />
      Unverified
    </span>
  );
}

function VerifyCertSection({ provider }: { provider: Provider }) {
  const [showCert, setShowCert] = useState(false);
  const [showInstructions, setShowInstructions] = useState(false);

  const pemChain = provider.mda_cert_chain_b64!
    .map((b64) => {
      const lines = b64.match(/.{1,64}/g) || [];
      return `-----BEGIN CERTIFICATE-----\n${lines.join("\n")}\n-----END CERTIFICATE-----`;
    })
    .join("\n\n");

  return (
    <div className="space-y-2">
      <div className="flex items-center gap-2">
        <button
          onClick={() => setShowInstructions(!showInstructions)}
          className="text-xs font-medium text-accent-brand hover:underline cursor-pointer inline-flex items-center gap-1"
        >
          <ShieldCheck size={12} />
          Verify this device independently
          <ChevronDown size={10} className={`transition-transform ${showInstructions ? "rotate-180" : ""}`} />
        </button>
      </div>

      {showInstructions && (
        <div className="rounded-lg bg-bg-tertiary p-3 space-y-3 text-xs text-text-secondary">
          <p>
            This provider&apos;s identity is signed by Apple&apos;s Device Attestation certificate authority.
            You can verify the certificate chain yourself to confirm this is a genuine Apple device.
          </p>

          <div className="space-y-1">
            <p className="font-medium text-text-primary">Step 1: Save the certificate chain</p>
            <p>Click below to view the PEM certificate, then copy it to a file (e.g. <code className="bg-bg-elevated px-1 rounded">provider.pem</code>).</p>
            <button
              onClick={() => setShowCert(!showCert)}
              className="text-accent-brand hover:underline cursor-pointer"
            >
              {showCert ? "Hide" : "Show"} certificate chain (PEM)
            </button>
            {showCert && (
              <pre className="mt-1 p-2 bg-bg-elevated rounded text-[10px] font-mono text-text-tertiary overflow-x-auto max-h-40 overflow-y-auto select-all">
                {pemChain}
              </pre>
            )}
          </div>

          <div className="space-y-1">
            <p className="font-medium text-text-primary">Step 2: Download Apple&apos;s Root CA</p>
            <p>
              Get Apple&apos;s Enterprise Attestation Root CA from{" "}
              <a href="https://www.apple.com/certificateauthority/private/" target="_blank" rel="noopener noreferrer"
                className="text-accent-brand hover:underline inline-flex items-center gap-0.5">
                apple.com/certificateauthority <ExternalLink size={9} />
              </a>
            </p>
          </div>

          <div className="space-y-1">
            <p className="font-medium text-text-primary">Step 3: Verify</p>
            <pre className="p-2 bg-bg-elevated rounded text-[10px] font-mono text-text-tertiary select-all">
{`openssl verify -CAfile AppleRootCA.pem provider.pem`}
            </pre>
            <p>If valid, this proves the device (serial: <code className="bg-bg-elevated px-1 rounded">{provider.mda_serial}</code>) is a real {provider.chip_name} verified by Apple.</p>

          </div>
        </div>
      )}
    </div>
  );
}

function ProviderCard({ provider }: { provider: Provider }) {
  const { mode } = useVerificationMode();
  const [expanded, setExpanded] = useState(false);
  const serial = mode === "normal" ? maskSerial(provider.serial_number) : provider.serial_number;

  return (
    <div className="rounded-xl bg-bg-secondary shadow-sm overflow-hidden">
      <div className="p-4 flex items-start justify-between">
        <div className="flex items-center gap-3">
          <div className="w-10 h-10 rounded-lg bg-accent-brand/10 flex items-center justify-center">
            <Cpu size={20} className="text-accent-brand" />
          </div>
          <div>
            <h3 className="text-sm font-semibold text-text-primary">{provider.chip_name}</h3>
            <p className="text-xs text-text-tertiary font-mono">
              {provider.hardware_model} · {serial}
            </p>
          </div>
        </div>
        <TrustBadge level={provider.trust_level} mdaVerified={provider.mda_verified} />
      </div>

      <div className="px-4 pb-3 grid grid-cols-3 gap-3">
        {[
          { label: "Memory", value: `${provider.memory_gb} GB` },
          { label: "GPU Cores", value: String(provider.gpu_cores) },
          { label: "Status", value: provider.status || "online", isStatus: true },
        ].map(({ label, value, isStatus }) => (
          <div key={label} className="rounded-lg bg-bg-primary/50 p-2.5">
            <p className="text-xs text-text-tertiary mb-1">{label}</p>
            <div className="flex items-center gap-1.5">
              {isStatus && (
                <span className={`w-2 h-2 rounded-full ${value === "online" ? "bg-accent-green" : "bg-accent-red"}`} />
              )}
              <p className="text-sm font-semibold text-text-primary capitalize">{value}</p>
            </div>
          </div>
        ))}
      </div>

      {provider.models?.length > 0 && (
        <div className="px-4 pb-3">
          <p className="text-xs text-text-tertiary mb-1.5">Models</p>
          <div className="flex flex-wrap gap-1.5">
            {provider.models.map((m) => (
              <span key={m} className="px-2 py-0.5 rounded-md bg-bg-tertiary text-xs text-text-secondary font-mono">
                {m.split("/").pop()}
              </span>
            ))}
          </div>
        </div>
      )}

      <button
        onClick={() => setExpanded(!expanded)}
        className="w-full flex items-center gap-2 px-4 py-2.5 border-t border-border-dim text-left hover:bg-bg-hover transition-colors"
      >
        <Lock size={12} className="text-text-tertiary" />
        <span className="text-xs text-text-secondary">Security Verification</span>
        <ChevronDown
          size={12}
          className={`ml-auto text-text-tertiary transition-transform ${expanded ? "rotate-180" : ""}`}
        />
      </button>

      {expanded && (
        <div className="px-4 pb-4 space-y-3 border-t border-border-dim/50">
          <div className="mt-3">
            <div className="flex items-center gap-1.5 mb-2">
              <Fingerprint size={12} className="text-text-tertiary" />
              <span className="text-xs text-text-tertiary font-medium">Secure Enclave</span>
            </div>
            <div className="space-y-1">
              <div className="flex items-center gap-2 text-xs">
                {provider.secure_enclave ? <Check size={12} className="text-accent-green" /> : <X size={12} className="text-accent-red" />}
                <span className="text-text-secondary">Hardware-bound P-256 identity</span>
              </div>
              <div className="flex items-center gap-2 text-xs">
                {provider.mda_verified ? <Check size={12} className="text-accent-green" /> : <X size={12} className="text-accent-amber" />}
                <span className="text-text-secondary">ACME device-attest-01</span>
              </div>
            </div>
          </div>

          <div>
            <div className="flex items-center gap-1.5 mb-2">
              <Lock size={12} className="text-text-tertiary" />
              <span className="text-xs text-text-tertiary font-medium">OS Security</span>
            </div>
            <div className="space-y-1">
              {[
                { ok: provider.sip_enabled, label: "System Integrity Protection" },
                { ok: provider.secure_boot_enabled, label: "Secure Boot" },
                { ok: provider.authenticated_root_enabled, label: "Authenticated Root Volume" },
              ].map(({ ok, label }) => (
                <div key={label} className="flex items-center gap-2 text-xs">
                  {ok ? <Check size={12} className="text-accent-green" /> : <X size={12} className="text-accent-red" />}
                  <span className="text-text-secondary">{label}</span>
                </div>
              ))}
            </div>
          </div>

          {provider.mda_verified && (
            <div>
              <div className="flex items-center gap-1.5 mb-2">
                <HardDrive size={12} className="text-text-tertiary" />
                <span className="text-xs text-text-tertiary font-medium">Apple Device Attestation</span>
              </div>
              <div className="space-y-1 text-xs text-text-secondary">
                <div className="flex items-center gap-2"><Check size={12} className="text-accent-green" /> Apple CA cert chain verified</div>
                {provider.mda_serial && <div className="flex items-center gap-2"><Check size={12} className="text-accent-green" /> Serial: {mode === "normal" ? maskSerial(provider.mda_serial) : provider.mda_serial}</div>}
                {provider.mda_os_version && <div className="flex items-center gap-2"><Check size={12} className="text-accent-green" /> macOS {provider.mda_os_version}</div>}
              </div>
            </div>
          )}

          {provider.system_volume_hash && (
            <div>
              <p className="text-xs text-text-tertiary mb-1">System Volume Hash</p>
              <p className="text-xs font-mono text-text-tertiary break-all bg-bg-tertiary rounded px-2 py-1">
                {provider.system_volume_hash}
              </p>
            </div>
          )}

          {provider.mda_cert_chain_b64 && provider.mda_cert_chain_b64.length > 0 && (
            <div className="pt-3 border-t border-border-dim/50">
              <VerifyCertSection provider={provider} />
            </div>
          )}
        </div>
      )}
    </div>
  );
}

export default function ProvidersPage() {
  const { ready, authenticated, login } = useAuth();
  const [providers, setProviders] = useState<Provider[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    async function fetchProviders() {
      try {
        const res = await fetch(`${ATTESTATION_API}/v1/providers/attestation`);
        if (!res.ok) throw new Error(`HTTP ${res.status}`);
        const json = await res.json();
        // Only show hardware-verified providers to consumers
        const all = json.providers || [];
        setProviders(all.filter((p: Provider) => p.trust_level === "hardware"));
      } catch (e) {
        setError(e instanceof Error ? e.message : String(e));
      } finally {
        setLoading(false);
      }
    }
    fetchProviders();
    const interval = setInterval(fetchProviders, 15000);
    return () => clearInterval(interval);
  }, []);

  if (loading) {
    return (
      <div className="flex items-center justify-center h-64">
        <Loader2 size={24} className="animate-spin text-accent-brand" />
      </div>
    );
  }

  if (error) {
    return (
      <div className="max-w-5xl mx-auto p-6">
        <p className="text-accent-red text-sm">Failed to load providers: {error}</p>
      </div>
    );
  }

  // Provider matching by wallet address is no longer available after Solana removal.
  // TODO: match by account_id once coordinator exposes it on the attestation endpoint.
  const myProvider = null as Provider | null;

  return (
    <div className="max-w-5xl mx-auto p-6 space-y-6">
      {/* Sign-in prompt for unauthenticated users */}
      {!authenticated && (
        <div className="rounded-xl bg-bg-secondary shadow-sm p-6">
          <div className="flex flex-col sm:flex-row items-start sm:items-center justify-between gap-4">
            <div>
              <h3 className="text-sm font-semibold text-text-primary mb-0.5">
                Sign in to view your provider earnings and set up a node
              </h3>
              <p className="text-sm text-text-secondary">
                Link your account to track your provider status, earnings, and manage your node.
              </p>
            </div>
            <button
              onClick={() => {
                trackEvent("login_cta_clicked", {
                  source: "providers_page",
                });
                login();
              }}
              disabled={!ready}
              className="inline-flex items-center justify-center gap-2 px-6 py-2.5 rounded-lg
                         bg-coral text-white font-medium text-sm
                         hover:opacity-90
                         disabled:opacity-40 disabled:cursor-not-allowed
                         transition-all shrink-0"
            >
              <Mail size={14} />
              {!ready ? "Loading..." : "Sign In"}
            </button>
          </div>
        </div>
      )}

      {/* My machines CTA — visible whenever the user is signed in, since the
          dashboard now lists all machines linked to their account (not just
          the one matching the connected wallet). */}
      {authenticated && (
        <Link
          href="/providers/me"
          className="block rounded-xl bg-accent-brand/5 hover:bg-accent-brand/10 transition-colors shadow-sm p-6"
        >
          <div className="flex items-center justify-between gap-4">
            <div>
              <h2 className="text-lg font-semibold text-text-primary mb-1">My Machines</h2>
              <p className="text-sm text-text-secondary">
                Status, earnings, and warnings for every provider linked to your account.
              </p>
            </div>
            <ArrowRight size={18} className="text-accent-brand shrink-0" />
          </div>
        </Link>
      )}

      {/* Network overview */}
      <div>
        <div className="flex items-center justify-between mb-4">
          <div>
            <h2 className="text-lg font-semibold text-text-primary">Network Providers</h2>
            <p className="text-sm text-text-tertiary mt-0.5">
              {providers.length} provider{providers.length !== 1 ? "s" : ""} online
            </p>
          </div>
          {!myProvider && (
            <Link
              href="/providers/setup"
              onClick={() => {
                trackEvent("provider_setup_clicked", {
                  source: "providers_page",
                });
              }}
              className="flex items-center gap-2 px-4 py-2 rounded-xl bg-accent-brand text-white text-sm font-medium hover:bg-accent-brand-hover transition-colors"
            >
              Become a Provider <ArrowRight size={14} />
            </Link>
          )}
        </div>

        {/* Summary stats */}
        <div className="grid grid-cols-4 gap-3 mb-6">
          {[
            { label: "Providers", value: providers.length },
            { label: "Hardware Trust", value: `${providers.filter((p) => p.trust_level === "hardware").length}/${providers.length}` },
            { label: "Apple MDA", value: `${providers.filter((p) => p.mda_verified).length}/${providers.length}` },
            { label: "Total Memory", value: `${providers.reduce((s, p) => s + (p.memory_gb || 0), 0)} GB` },
          ].map(({ label, value }) => (
            <div key={label} className="rounded-xl bg-bg-secondary shadow-sm p-4">
              <p className="text-xs text-text-tertiary mb-1">{label}</p>
              <p className="text-xl font-bold text-text-primary">{value}</p>
            </div>
          ))}
        </div>

        {/* Provider cards */}
        <div className="space-y-4">
          {providers.map((p) => (
            <ProviderCard key={p.provider_id} provider={p} />
          ))}
        </div>

        {providers.length === 0 && (
          <div className="text-center py-16 text-text-tertiary">
            <Server size={32} className="mx-auto mb-3 opacity-50" />
            <p className="text-sm">No providers online</p>
            <Link
              href="/providers/setup"
              onClick={() => {
                trackEvent("provider_setup_clicked", {
                  source: "providers_empty_state",
                });
              }}
              className="inline-flex items-center gap-1.5 mt-3 text-sm text-accent-brand font-medium hover:underline"
            >
              Learn how to become a provider <ArrowRight size={14} />
            </Link>
          </div>
        )}
      </div>
    </div>
  );
}
