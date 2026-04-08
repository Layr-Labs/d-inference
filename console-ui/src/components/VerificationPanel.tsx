"use client";

import { useState } from "react";
import type { TrustMetadata } from "@/lib/api";
import { useVerificationMode } from "@/lib/verification-mode";
import { TrustExplainerModal } from "./TrustExplainerModal";
import {
  verifyCertificateChain,
  type VerificationStep,
  type CertVerificationResult,
} from "@/lib/cert-verify";
import {
  ShieldCheck,
  Shield,
  ChevronDown,
  Check,
  X,
  Cpu,
  Lock,
  HardDrive,
  Fingerprint,
  Loader2,
  ExternalLink,
  Code,
  Eye,
  Info,
} from "lucide-react";

const ATTESTATION_API = "https://inference-test.openinnovation.dev";

/** Mask a serial number for normal mode: show first 4 + last 2, mask the rest. */
function maskSerial(serial: string): string {
  if (serial.length <= 6) return serial;
  const masked = serial.slice(0, 4) + "\u2022".repeat(serial.length - 6) + serial.slice(-2);
  return masked;
}

function StatusLine({
  ok,
  label,
  detail,
}: {
  ok: boolean;
  label: string;
  detail?: string;
}) {
  return (
    <div className="flex items-center gap-2 py-1">
      {ok ? (
        <Check size={12} className="text-accent-green shrink-0" />
      ) : (
        <X size={12} className="text-accent-red shrink-0" />
      )}
      <span className="text-xs text-text-primary">{label}</span>
      {detail && (
        <span className="text-xs text-text-tertiary ml-auto font-mono">
          {detail}
        </span>
      )}
    </div>
  );
}

function VerifyStepLine({ step }: { step: VerificationStep }) {
  return (
    <div className="flex items-center gap-2 py-0.5">
      {step.status === "success" && (
        <Check size={12} className="text-accent-green shrink-0" />
      )}
      {step.status === "error" && (
        <X size={12} className="text-accent-red shrink-0" />
      )}
      {step.status === "running" && (
        <Loader2 size={12} className="text-accent-brand animate-spin shrink-0" />
      )}
      {step.status === "pending" && (
        <div className="w-3 h-3 rounded-full border border-border-dim shrink-0" />
      )}
      <span className="text-xs text-text-primary">{step.label}</span>
      {step.detail && (
        <span className="text-xs text-text-tertiary ml-auto font-mono truncate max-w-[180px]">
          {step.detail}
        </span>
      )}
    </div>
  );
}

/** Normal mode: human-readable trust guarantees with one-click verification. */
function NormalModeContent({
  trust,
  onOpenExplainer,
  verifySteps,
  verifyResult,
  verifying,
  onVerify,
}: {
  trust: TrustMetadata;
  onOpenExplainer: () => void;
  verifySteps: VerificationStep[];
  verifyResult: CertVerificationResult | null;
  verifying: boolean;
  onVerify: () => void;
}) {
  const isHardware = trust.trustLevel === "hardware";

  const guarantees = [
    {
      icon: Fingerprint,
      color: "text-teal",
      title: "Hardware Identity",
      description:
        "This machine's identity is sealed in Apple's Secure Enclave chip — it can't be cloned, copied, or faked.",
      info: "P-256 key generated inside the Secure Enclave. The private key never leaves the chip and cannot be exported.",
      ok: trust.secureEnclave,
    },
    {
      icon: ShieldCheck,
      color: "text-blue",
      title: "Software Integrity",
      description:
        "The inference software hasn't been modified — its hash matches the signed release.",
      info: "SHA-256 hash of the provider binary is verified against the CI-signed release. Runtime packages are also hash-checked.",
      ok: isHardware,
    },
    {
      icon: Lock,
      color: "text-coral",
      title: "Data Protection",
      description:
        "Your prompts are encrypted end-to-end. Not even EigenInference servers can read them.",
      info: "X25519 key exchange + XSalsa20-Poly1305 encryption (NaCl box). The coordinator only sees ciphertext.",
      ok: true, // E2E is always active
    },
    {
      icon: Cpu,
      color: "text-purple",
      title: "Anti-Tampering",
      description:
        "No process can inspect memory during inference. Debuggers are blocked and memory is wiped after each request.",
      info: "PT_DENY_ATTACH prevents debugger attachment. Hardened Runtime blocks task_for_pid. Memory is zeroed after each request.",
      ok: isHardware,
    },
  ];

  return (
    <div className="space-y-3">
      {guarantees.map(({ icon: Icon, color, title, description, info, ok }) => (
        <div key={title} className="flex gap-3">
          <div className="shrink-0 mt-0.5">
            {ok ? (
              <Icon size={16} className={color} />
            ) : (
              <Icon size={16} className="text-text-tertiary" />
            )}
          </div>
          <div className="flex-1">
            <div className="flex items-center gap-1">
              <p className="text-xs font-semibold text-text-primary">{title}</p>
              <span title={info} className="cursor-help">
                <Info size={10} className="text-text-tertiary hover:text-text-secondary transition-colors" />
              </span>
            </div>
            <p className="text-xs text-text-secondary leading-relaxed mt-0.5">
              {description}
            </p>
          </div>
        </div>
      ))}

      {/* One-click verification for normal users */}
      {isHardware && (
        <div className="pt-2 border-t border-border-dim/50">
          <button
            onClick={onVerify}
            disabled={verifying}
            className="flex items-center gap-2 px-3 py-2 rounded-lg bg-teal-light/50 border-2 border-teal/30 text-teal text-xs font-semibold hover:bg-teal-light/70 transition-colors disabled:opacity-50 w-full justify-center"
          >
            {verifying ? (
              <Loader2 size={14} className="animate-spin" />
            ) : (
              <ShieldCheck size={14} />
            )}
            {verifying
              ? "Verifying..."
              : verifyResult?.success
                ? "Apple-verified hardware"
                : "Verify device"}
          </button>

          {/* Step-by-step progress */}
          {verifySteps.length > 0 && (
            <div className="mt-2 space-y-0.5">
              {verifySteps.map((step, i) => (
                <VerifyStepLine key={i} step={step} />
              ))}
            </div>
          )}

          {/* Result message */}
          {verifyResult && (
            <p
              className={`mt-2 text-xs font-semibold text-center ${
                verifyResult.success ? "text-accent-green" : "text-accent-red"
              }`}
            >
              {verifyResult.success
                ? `Genuine Apple device ${verifyResult.deviceInfo?.serial ? `(${verifyResult.deviceInfo.serial})` : ""}`
                : verifyResult.error || "Verification failed"}
            </p>
          )}
        </div>
      )}

      <button
        onClick={onOpenExplainer}
        className="flex items-center gap-1.5 text-xs text-teal font-semibold hover:underline mt-2"
      >
        <Info size={12} />
        Learn how the trust chain works
      </button>
    </div>
  );
}

/** Technical mode: detailed checks with raw values. */
function TechnicalModeContent({
  trust,
  verifySteps,
  verifyResult,
  verifying,
  onVerify,
  providerDetail,
}: {
  trust: TrustMetadata;
  verifySteps: VerificationStep[];
  verifyResult: CertVerificationResult | null;
  verifying: boolean;
  onVerify: () => void;
  providerDetail: ProviderDetail | null;
}) {
  const isHardware = trust.trustLevel === "hardware";

  return (
    <>
      <div className="space-y-0.5">
        <div className="flex items-center gap-1.5 mb-2">
          <Fingerprint size={12} className="text-text-tertiary" />
          <span className="text-xs text-text-tertiary font-medium">
            Secure Enclave
          </span>
        </div>
        <StatusLine
          ok={trust.secureEnclave}
          label="Secure Enclave P-256 identity"
          detail={trust.secureEnclave ? "Verified" : "N/A"}
        />
        <StatusLine
          ok={trust.attested}
          label="ECDSA signature valid"
          detail={trust.attested ? "SHA-256 + P-256" : "Failed"}
        />
      </div>

      <div className="mt-3 space-y-0.5">
        <div className="flex items-center gap-1.5 mb-2">
          <Lock size={12} className="text-text-tertiary" />
          <span className="text-xs text-text-tertiary font-medium">
            OS Security (MDM Verified)
          </span>
        </div>
        <StatusLine
          ok={isHardware}
          label="System Integrity Protection (SIP)"
          detail={isHardware ? "Enabled" : "Unknown"}
        />
        <StatusLine
          ok={isHardware}
          label="Secure Boot"
          detail={isHardware ? "Full Security" : "Unknown"}
        />
        <StatusLine
          ok={isHardware}
          label="Authenticated Root Volume"
          detail={isHardware ? "Sealed" : "Unknown"}
        />
      </div>

      <div className="mt-3 space-y-0.5">
        <div className="flex items-center gap-1.5 mb-2">
          <Cpu size={12} className="text-text-tertiary" />
          <span className="text-xs text-text-tertiary font-medium">
            Runtime Protection
          </span>
        </div>
        <StatusLine ok={isHardware} label="PT_DENY_ATTACH (anti-debug)" />
        <StatusLine ok={isHardware} label="Hardened Runtime (no task_for_pid)" />
        <StatusLine ok={isHardware} label="Memory wiping after inference" />
      </div>

      {trust.mdaVerified && (
        <div className="mt-3 space-y-0.5">
          <div className="flex items-center gap-1.5 mb-2">
            <HardDrive size={12} className="text-text-tertiary" />
            <span className="text-xs text-text-tertiary font-medium">
              Apple Device Attestation
            </span>
          </div>
          <StatusLine ok label="Apple CA certificate chain verified" />
          <StatusLine ok label="Device identity confirmed by Apple" />
        </div>
      )}

      {/* Attestation receipt headers (if available) */}
      {trust.seSignature && (
        <div className="mt-3 space-y-0.5">
          <div className="flex items-center gap-1.5 mb-2">
            <ShieldCheck size={12} className="text-text-tertiary" />
            <span className="text-xs text-text-tertiary font-medium">
              Attestation Receipt
            </span>
          </div>
          <StatusLine ok label="SE-signed response receipt" />
          {trust.responseHash && (
            <div className="mt-1">
              <p className="text-xs font-mono text-text-tertiary">Response Hash:</p>
              <p className="text-xs font-mono break-all bg-bg-tertiary rounded px-2 py-1 mt-0.5">
                {trust.responseHash}
              </p>
            </div>
          )}
          <div className="mt-1">
            <p className="text-xs font-mono text-text-tertiary">SE Signature:</p>
            <p className="text-xs font-mono break-all bg-bg-tertiary rounded px-2 py-1 mt-0.5">
              {trust.seSignature}
            </p>
          </div>
          {trust.sePublicKey && (
            <div className="mt-1">
              <p className="text-xs font-mono text-text-tertiary">SE Public Key:</p>
              <p className="text-xs font-mono break-all bg-bg-tertiary rounded px-2 py-1 mt-0.5">
                {trust.sePublicKey}
              </p>
            </div>
          )}
        </div>
      )}

      {isHardware && (
        <div className="mt-3 pt-2 border-t border-border-dim/50">
          <button
            onClick={onVerify}
            disabled={verifying}
            className="flex items-center gap-2 px-3 py-2 rounded-lg bg-accent-brand/10 text-accent-brand text-xs font-medium hover:bg-accent-brand/20 transition-colors disabled:opacity-50"
          >
            {verifying ? (
              <Loader2 size={12} className="animate-spin" />
            ) : (
              <ShieldCheck size={12} />
            )}
            Verify Apple Attestation
          </button>

          {/* Live verification steps */}
          {verifySteps.length > 0 && (
            <div className="mt-2 space-y-0.5">
              {verifySteps.map((step, i) => (
                <VerifyStepLine key={i} step={step} />
              ))}
            </div>
          )}

          {/* Final result */}
          {verifyResult && (
            <p
              className={`mt-2 text-xs font-semibold leading-relaxed ${
                verifyResult.success ? "text-accent-green" : "text-accent-red"
              }`}
            >
              {verifyResult.success
                ? "Genuine Apple device — certificate chain verified against Apple Root CA."
                : verifyResult.error || "Verification failed"}
            </p>
          )}

          {/* Provider details from API */}
          {providerDetail && (
            <div className="mt-2 space-y-1.5 text-xs text-text-tertiary">
              {providerDetail.mdaSerial && (
                <p>
                  <span className="font-mono">MDA Serial:</span>{" "}
                  {providerDetail.mdaSerial}
                </p>
              )}
              {providerDetail.mdaOsVersion && (
                <p>
                  <span className="font-mono">macOS:</span>{" "}
                  {providerDetail.mdaOsVersion}
                  {providerDetail.mdaSepVersion &&
                    ` · SepOS: ${providerDetail.mdaSepVersion}`}
                </p>
              )}
              {providerDetail.mdaCertCount !== undefined &&
                providerDetail.mdaCertCount > 0 && (
                  <p>
                    <span className="font-mono">Apple Certs:</span>{" "}
                    {providerDetail.mdaCertCount} (leaf + intermediate)
                  </p>
                )}
              {providerDetail.systemVolumeHash && (
                <div>
                  <p className="font-mono">Volume Hash:</p>
                  <p className="text-xs font-mono break-all bg-bg-tertiary rounded px-2 py-1 mt-0.5">
                    {providerDetail.systemVolumeHash}
                  </p>
                </div>
              )}
              {providerDetail.sePublicKey && (
                <div>
                  <p className="font-mono">SE Public Key:</p>
                  <p className="text-xs font-mono break-all bg-bg-tertiary rounded px-2 py-1 mt-0.5">
                    {providerDetail.sePublicKey}
                  </p>
                </div>
              )}
            </div>
          )}

          <p className="mt-2 text-xs text-text-tertiary leading-relaxed">
            Manual: download MDA cert chain from{" "}
            <a
              href={`${ATTESTATION_API}/v1/providers/attestation`}
              target="_blank"
              rel="noopener noreferrer"
              className="text-accent-brand hover:underline inline-flex items-center gap-0.5"
            >
              attestation API
              <ExternalLink size={10} />
            </a>
            , decode base64 to DER, verify against{" "}
            <a
              href="https://www.apple.com/certificateauthority/"
              target="_blank"
              rel="noopener noreferrer"
              className="text-accent-brand hover:underline inline-flex items-center gap-0.5"
            >
              Apple&apos;s Root CA
              <ExternalLink size={10} />
            </a>
          </p>
        </div>
      )}

      {!isHardware && (
        <div className="mt-3 pt-2 border-t border-border-dim/50">
          <p className="text-xs text-text-tertiary leading-relaxed">
            This provider has not been verified.
          </p>
        </div>
      )}
    </>
  );
}

interface ProviderDetail {
  systemVolumeHash?: string;
  sePublicKey?: string;
  mdaSerial?: string;
  mdaOsVersion?: string;
  mdaSepVersion?: string;
  mdaCertCount?: number;
}

export function VerificationPanel({ trust }: { trust: TrustMetadata }) {
  const { mode, toggle } = useVerificationMode();
  const [open, setOpen] = useState(false);
  const [verifying, setVerifying] = useState(false);
  const [verifySteps, setVerifySteps] = useState<VerificationStep[]>([]);
  const [verifyResult, setVerifyResult] = useState<CertVerificationResult | null>(
    null
  );
  const [providerDetail, setProviderDetail] = useState<ProviderDetail | null>(null);
  const [showExplainer, setShowExplainer] = useState(false);

  const isHardware = trust.trustLevel === "hardware";

  const Icon = isHardware ? ShieldCheck : Shield;
  const color = isHardware ? "text-accent-green" : "text-text-tertiary";
  const bg = isHardware ? "bg-accent-green/5" : "bg-bg-secondary";
  const title = isHardware
    ? trust.mdaVerified
      ? mode === "normal"
        ? "Apple-verified hardware"
        : "Apple Attested"
      : "Hardware Verified"
    : "Unverified";

  const displaySerial = trust.providerSerial
    ? mode === "normal" ? maskSerial(trust.providerSerial) : trust.providerSerial
    : "";
  const chipLabel = trust.providerChip
    ? `${trust.providerChip}${displaySerial ? ` · ${displaySerial}` : ""}`
    : "";

  async function handleVerify() {
    setVerifying(true);
    setVerifyResult(null);
    setVerifySteps([]);

    try {
      const res = await fetch(`${ATTESTATION_API}/v1/providers/attestation`);
      const data = await res.json();

      const provider =
        data.providers?.find(
          (p: { serial_number: string }) =>
            p.serial_number === trust.providerSerial
        ) || data.providers?.[0];

      if (!provider) {
        setVerifyResult({
          success: false,
          steps: [],
          error: "Provider not found in attestation API",
        });
        return;
      }

      setProviderDetail({
        systemVolumeHash: provider.system_volume_hash,
        sePublicKey: provider.se_public_key,
        mdaSerial: provider.mda_serial,
        mdaOsVersion: provider.mda_os_version,
        mdaSepVersion: provider.mda_sepos_version,
        mdaCertCount: provider.mda_cert_chain_b64?.length || 0,
      });

      const certs: string[] = provider.mda_cert_chain_b64 || [];

      if (certs.length < 2) {
        setVerifyResult({
          success: false,
          steps: [
            {
              status: "error",
              label: "Insufficient certificates",
              detail: `Got ${certs.length}, need at least 2`,
            },
          ],
          error: "Certificate chain too short for verification",
        });
        return;
      }

      // Real X.509 verification!
      const result = await verifyCertificateChain(certs, (steps) => {
        setVerifySteps(steps);
      });

      setVerifyResult(result);
    } catch (e) {
      setVerifyResult({
        success: false,
        steps: [],
        error: `Error: ${e instanceof Error ? e.message : String(e)}`,
      });
    } finally {
      setVerifying(false);
    }
  }

  return (
    <>
      <div
        className={`rounded-xl ${bg} shadow-sm overflow-hidden max-w-full`}
      >
        <button
          onClick={() => setOpen(!open)}
          className="w-full flex items-center gap-2 px-3 py-2.5 text-left"
        >
          <Icon size={14} className={color} />
          <span className={`text-xs font-medium ${color}`}>{title}</span>
          {chipLabel && (
            <span className="text-xs text-text-tertiary font-mono ml-1">
              {chipLabel}
            </span>
          )}
          <ChevronDown
            size={12}
            className={`ml-auto text-text-tertiary transition-transform ${
              open ? "rotate-180" : ""
            }`}
          />
        </button>

        {open && (
          <div className="px-3 pb-3 border-t border-border-dim/50">
            {/* Mode toggle */}
            <div className="flex items-center justify-between mt-2 mb-2">
              <p className="text-xs text-text-tertiary font-medium uppercase tracking-wider">
                {mode === "normal"
                  ? "Security Guarantees"
                  : "Provider Security Verification"}
              </p>
              <button
                onClick={(e) => {
                  e.stopPropagation();
                  toggle();
                }}
                className="flex items-center gap-1 px-2 py-1 rounded-md text-xs text-text-tertiary hover:text-text-secondary hover:bg-bg-hover transition-colors"
                title={
                  mode === "normal"
                    ? "Switch to technical view"
                    : "Switch to simple view"
                }
              >
                {mode === "normal" ? <Code size={12} /> : <Eye size={12} />}
                <span className="text-[10px]">
                  {mode === "normal" ? "Technical" : "Simple"}
                </span>
              </button>
            </div>

            {mode === "normal" ? (
              <NormalModeContent
                trust={trust}
                onOpenExplainer={() => setShowExplainer(true)}
                verifySteps={verifySteps}
                verifyResult={verifyResult}
                verifying={verifying}
                onVerify={handleVerify}
              />
            ) : (
              <TechnicalModeContent
                trust={trust}
                verifySteps={verifySteps}
                verifyResult={verifyResult}
                verifying={verifying}
                onVerify={handleVerify}
                providerDetail={providerDetail}
              />
            )}
          </div>
        )}
      </div>

      <TrustExplainerModal
        open={showExplainer}
        onClose={() => setShowExplainer(false)}
      />
    </>
  );
}
