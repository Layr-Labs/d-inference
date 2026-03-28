"use client";

import { useState } from "react";
import type { TrustMetadata } from "@/lib/api";
import {
  ShieldCheck,
  ShieldAlert,
  Shield,
  ChevronDown,
  Check,
  X,
  Cpu,
  Lock,
  HardDrive,
  Fingerprint,
} from "lucide-react";

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
        <span className="text-[10px] text-text-tertiary ml-auto font-mono">
          {detail}
        </span>
      )}
    </div>
  );
}

export function VerificationPanel({ trust }: { trust: TrustMetadata }) {
  const [open, setOpen] = useState(false);

  const isHardware = trust.trustLevel === "hardware";
  const isSelfSigned = trust.trustLevel === "self_signed";

  const Icon = isHardware
    ? ShieldCheck
    : isSelfSigned
    ? ShieldAlert
    : Shield;
  const color = isHardware
    ? "text-accent-green"
    : isSelfSigned
    ? "text-accent-amber"
    : "text-text-tertiary";
  const bg = isHardware
    ? "bg-accent-green-dim/30 border-accent-green/20"
    : isSelfSigned
    ? "bg-accent-amber-dim/30 border-accent-amber/20"
    : "bg-bg-tertiary border-border-dim";
  const title = isHardware
    ? trust.mdaVerified
      ? "Apple Attested"
      : "Hardware Verified"
    : isSelfSigned
    ? "Self-Signed"
    : "Unverified";

  return (
    <div className={`rounded-lg border ${bg} overflow-hidden`}>
      <button
        onClick={() => setOpen(!open)}
        className="w-full flex items-center gap-2 px-3 py-2 text-left"
      >
        <Icon size={14} className={color} />
        <span className={`text-xs font-medium ${color}`}>{title}</span>
        <ChevronDown
          size={12}
          className={`ml-auto text-text-tertiary transition-transform ${
            open ? "rotate-180" : ""
          }`}
        />
      </button>

      {open && (
        <div className="px-3 pb-3 border-t border-border-dim/50">
          <p className="text-[10px] text-text-tertiary mt-2 mb-2 font-mono uppercase tracking-wider">
            Provider Security Verification
          </p>

          <div className="space-y-0.5">
            <div className="flex items-center gap-1.5 mb-2">
              <Fingerprint size={11} className="text-text-tertiary" />
              <span className="text-[10px] font-mono text-text-tertiary uppercase tracking-wider">
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
              <Lock size={11} className="text-text-tertiary" />
              <span className="text-[10px] font-mono text-text-tertiary uppercase tracking-wider">
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
              <Cpu size={11} className="text-text-tertiary" />
              <span className="text-[10px] font-mono text-text-tertiary uppercase tracking-wider">
                Runtime Protection
              </span>
            </div>
            <StatusLine ok={isHardware} label="PT_DENY_ATTACH (anti-debug)" />
            <StatusLine ok={isHardware} label="Hardened Runtime (no task_for_pid)" />
            <StatusLine ok={isHardware} label="Memory wiping after inference" />
            <StatusLine ok={isHardware} label="Python path locked to signed bundle" />
          </div>

          {trust.mdaVerified && (
            <div className="mt-3 space-y-0.5">
              <div className="flex items-center gap-1.5 mb-2">
                <HardDrive size={11} className="text-text-tertiary" />
                <span className="text-[10px] font-mono text-text-tertiary uppercase tracking-wider">
                  Apple Device Attestation
                </span>
              </div>
              <StatusLine
                ok={true}
                label="Apple CA certificate chain verified"
              />
              <StatusLine ok={true} label="Device identity confirmed by Apple" />
            </div>
          )}

          <div className="mt-3 pt-2 border-t border-border-dim/50">
            <p className="text-[10px] text-text-tertiary leading-relaxed">
              {isHardware
                ? "This provider's security posture was independently verified by querying Apple's MDM framework. SIP, Secure Boot, and the sealed system volume were confirmed. The provider cannot read your inference data."
                : isSelfSigned
                ? "This provider presented a Secure Enclave attestation but has not been independently verified via MDM."
                : "This provider has not been verified. Responses should not be trusted with sensitive data."}
            </p>
          </div>

          {isHardware && (
            <div className="mt-3 pt-2 border-t border-border-dim/50">
              <p className="text-[10px] font-mono text-text-tertiary uppercase tracking-wider mb-2">
                Verify Yourself
              </p>
              <div className="space-y-2 text-[10px] text-text-tertiary leading-relaxed">
                <p>
                  <span className="text-text-secondary font-medium">1.</span> Visit{" "}
                  <a
                    href="/providers"
                    className="text-accent-purple hover:underline"
                  >
                    /providers
                  </a>{" "}
                  and expand the Security Verification panel
                </p>
                <p>
                  <span className="text-text-secondary font-medium">2.</span> Click{" "}
                  <span className="text-accent-purple font-medium">Verify Apple Attestation</span>{" "}
                  to check the certificate chain in your browser
                </p>
                <p>
                  <span className="text-text-secondary font-medium">3.</span> For manual verification: download the MDA cert chain (base64 DER),
                  decode it, and verify against{" "}
                  <a
                    href="https://www.apple.com/certificateauthority/"
                    target="_blank"
                    rel="noopener noreferrer"
                    className="text-accent-purple hover:underline"
                  >
                    Apple&apos;s Enterprise Attestation Root CA
                  </a>
                </p>
                <p>
                  <span className="text-text-secondary font-medium">4.</span> Every inference response includes an{" "}
                  <span className="font-mono text-text-secondary">se_signature</span>{" "}
                  signed by the provider&apos;s Secure Enclave key, verifiable against the SE public key shown on the providers page
                </p>
              </div>
            </div>
          )}
        </div>
      )}
    </div>
  );
}
