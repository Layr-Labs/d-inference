"use client";

import type { TrustMetadata } from "@/lib/api";
import type { VerificationStep, CertVerificationResult } from "@/lib/cert-verify";
import {
  ShieldCheck,
  Cpu,
  Lock,
  HardDrive,
  Fingerprint,
  Loader2,
  ExternalLink,
} from "lucide-react";
import { StatusLine, VerifyStepLine } from "./StatusLine";
import { clientCoordinatorUrl } from "@/lib/coordinator-url";
import type { ProviderDetail } from "./types";

/** Technical mode: detailed checks with raw values. */
export function TechnicalMode({
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

          {verifySteps.length > 0 && (
            <div className="mt-2 space-y-0.5">
              {verifySteps.map((step, i) => (
                <VerifyStepLine key={i} step={step} />
              ))}
            </div>
          )}

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
              href={`${clientCoordinatorUrl()}/v1/providers/attestation`}
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
