"use client";

// The trust chain as a connected vertical ladder: Secure Enclave → OS security
// → MDM identity → Apple Device Attestation. Each link is green when verified
// and dashed/grey where it breaks, so "where is the chain broken" is obvious at
// a glance. Serves both the operator ("why am I blocked") and the trust-minded
// visitor ("is this a real, secure Apple device"). The Apple Root CA check runs
// the same client-side verifier the public stats page uses.

import { useEffect, useState } from "react";
import {
  CheckCircle2,
  ExternalLink,
  Loader2,
  Shield,
  XCircle,
} from "lucide-react";
import {
  verifyCertificateChain,
  type CertVerificationResult,
  type VerificationStep,
} from "@/lib/cert-verify";
import type { MyProvider } from "../types";
import { formatRelative, maskSerial } from "./format";

function CheckLine({ ok, label }: { ok: boolean; label: string }) {
  return (
    <div className="flex items-center gap-2 text-xs">
      {ok ? (
        <CheckCircle2 size={12} className="text-accent-green shrink-0" />
      ) : (
        <XCircle size={12} className="text-accent-red shrink-0" />
      )}
      <span className="text-text-secondary">{label}</span>
    </div>
  );
}

function ChainNode({
  ok,
  title,
  last = false,
  children,
}: {
  ok: boolean;
  title: string;
  last?: boolean;
  children: React.ReactNode;
}) {
  return (
    <div className="flex gap-3">
      <div className="flex flex-col items-center">
        <div
          className={`w-6 h-6 rounded-full flex items-center justify-center shrink-0 ${
            ok ? "bg-accent-green/15 text-accent-green" : "bg-accent-amber/15 text-accent-amber"
          }`}
        >
          {ok ? <CheckCircle2 size={14} /> : <XCircle size={14} />}
        </div>
        {!last && <div className={`w-px flex-1 my-1 ${ok ? "bg-accent-green/40" : "bg-border-subtle"}`} />}
      </div>
      <div className="flex-1 pb-4 min-w-0">
        <p className="text-xs font-semibold text-text-primary mb-1.5">{title}</p>
        <div className="space-y-1">{children}</div>
      </div>
    </div>
  );
}

function VerifyStepLine({ step }: { step: VerificationStep }) {
  return (
    <div className="flex items-center gap-2 text-[11px]">
      {step.status === "success" ? (
        <CheckCircle2 size={11} className="text-accent-green shrink-0" />
      ) : step.status === "error" ? (
        <XCircle size={11} className="text-accent-red shrink-0" />
      ) : step.status === "running" ? (
        <Loader2 size={11} className="text-accent-brand animate-spin shrink-0" />
      ) : (
        <span className="w-[11px] h-[11px] rounded-full border border-border-subtle shrink-0" />
      )}
      <span className={step.status === "error" ? "text-accent-red" : "text-text-secondary"}>
        {step.label}
        {step.detail ? <span className="text-text-tertiary"> — {step.detail}</span> : null}
      </span>
    </div>
  );
}

export function AttestationPanel({
  provider: p,
  challengeMaxAgeSeconds,
}: {
  provider: MyProvider;
  challengeMaxAgeSeconds: number;
}) {
  const [steps, setSteps] = useState<VerificationStep[]>([]);
  const [result, setResult] = useState<CertVerificationResult | null>(null);
  const [verifying, setVerifying] = useState(false);

  // Each chain link is "ok" only when all of its sub-checks pass; the spine
  // renders green up to the first broken link so the gap is obvious.
  const certs = p.mda_cert_chain_b64 ?? [];
  const enclaveOK = p.secure_enclave && p.se_key_bound;
  const osOK = p.sip_enabled && p.secure_boot_enabled && p.authenticated_root_enabled && p.runtime_verified;
  const mdmOK = Boolean(p.mda_serial || p.mda_udid);

  // Staleness needs the wall clock, so compute it in an effect (never during
  // render) to keep the component pure.
  const [challengeStale, setChallengeStale] = useState(false);
  useEffect(() => {
    if (!p.last_challenge_verified) {
      setChallengeStale(false);
      return;
    }
    const age = (Date.now() - new Date(p.last_challenge_verified).getTime()) / 1000;
    setChallengeStale(age > (challengeMaxAgeSeconds || 360));
  }, [p.last_challenge_verified, challengeMaxAgeSeconds]);

  async function handleVerify() {
    if (certs.length < 2 || verifying) return;
    setVerifying(true);
    setResult(null);
    try {
      const r = await verifyCertificateChain(certs, (s) => setSteps(s));
      setResult(r);
    } catch {
      setResult({ success: false, steps, error: "Verification failed" });
    } finally {
      setVerifying(false);
    }
  }

  return (
    <div>
      <ChainNode ok={enclaveOK} title="Secure Enclave">
        <CheckLine ok={p.secure_enclave} label="Hardware-bound P-256 identity" />
        <CheckLine ok={p.se_key_bound} label="SE key bound to MDA nonce" />
        <CheckLine ok={p.acme_verified} label="ACME device-attest-01" />
      </ChainNode>

      <ChainNode ok={osOK} title="OS security">
        <CheckLine ok={p.sip_enabled} label="System Integrity Protection" />
        <CheckLine ok={p.secure_boot_enabled} label="Secure Boot" />
        <CheckLine ok={p.authenticated_root_enabled} label="Authenticated Root Volume" />
        <CheckLine ok={p.runtime_verified} label="Runtime hashes match manifest" />
        {p.system_volume_hash && (
          <div className="mt-1.5">
            <p className="text-[10px] uppercase tracking-wider text-text-tertiary mb-1">System volume hash</p>
            <p className="text-[11px] font-mono text-text-tertiary break-all bg-bg-tertiary rounded px-2 py-1 max-h-16 overflow-y-auto">
              {p.system_volume_hash}
            </p>
          </div>
        )}
      </ChainNode>

      <ChainNode ok={mdmOK} title="MDM device identity">
        {mdmOK ? (
          <div className="space-y-0.5 text-[11px] font-mono text-text-secondary">
            {p.mda_serial && <div>serial {maskSerial(p.mda_serial)}</div>}
            {p.mda_udid && <div>udid {maskSerial(p.mda_udid)}</div>}
            {p.mda_os_version && <div>macOS {p.mda_os_version}</div>}
            {p.mda_sepos_version && <div>SEPOS {p.mda_sepos_version}</div>}
          </div>
        ) : (
          <p className="text-xs text-text-tertiary">No MDM device record.</p>
        )}
      </ChainNode>

      <ChainNode ok={p.mda_verified} title="Apple Device Attestation" last>
        <CheckLine
          ok={p.mda_verified}
          label={
            certs.length > 0
              ? `Apple CA cert chain (${certs.length} cert${certs.length === 1 ? "" : "s"})`
              : "Apple CA cert chain"
          }
        />
        {certs.length >= 2 && (
          <div className="mt-2 space-y-2">
            <button
              type="button"
              onClick={handleVerify}
              disabled={verifying}
              className="focus-ring inline-flex items-center gap-1.5 px-2.5 py-1.5 rounded-md bg-accent-brand/10 text-accent-brand text-xs font-medium hover:bg-accent-brand/15 disabled:opacity-60 transition-colors"
            >
              {verifying ? <Loader2 size={12} className="animate-spin" /> : <Shield size={12} />}
              Verify against Apple Root CA
            </button>
            {steps.length > 0 && (
              <div className="space-y-1 rounded-lg bg-bg-tertiary/40 p-2.5">
                {steps.map((s, i) => (
                  <VerifyStepLine key={i} step={s} />
                ))}
                {result && (
                  <p className={`text-[11px] font-medium mt-1 ${result.success ? "text-accent-green" : "text-accent-red"}`}>
                    {result.success ? "✓ Verified Apple-attested device" : `✗ ${result.error || "Verification failed"}`}
                  </p>
                )}
              </div>
            )}
          </div>
        )}
        <a
          href="https://www.apple.com/certificateauthority/private/"
          target="_blank"
          rel="noopener noreferrer"
          className="inline-flex items-center gap-1 text-[11px] text-accent-brand hover:underline mt-2"
        >
          Apple Root CA reference <ExternalLink size={10} />
        </a>
      </ChainNode>

      <div className="flex flex-wrap items-center gap-x-4 gap-y-1 pt-2 border-t border-border-dim/40 text-[11px] text-text-tertiary">
        <span>
          Last challenge:{" "}
          <span className={challengeStale ? "text-accent-amber" : "text-text-secondary"}>
            {formatRelative(p.last_challenge_verified)}
          </span>
        </span>
        {p.failed_challenges > 0 && (
          <span className="text-accent-amber">{p.failed_challenges} failed</span>
        )}
        <span>
          Runtime:{" "}
          <span className={p.runtime_verified ? "text-accent-green" : "text-accent-red"}>
            {p.runtime_verified ? "verified" : "unverified"}
          </span>
        </span>
      </div>
    </div>
  );
}
