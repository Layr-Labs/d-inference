"use client";

import type { TrustMetadata } from "@/lib/api";
import {
  ShieldCheck,
  Cpu,
  Lock,
  HardDrive,
  Fingerprint,
} from "lucide-react";
import { StatusLine } from "./StatusLine";

/** Technical mode: detailed checks without identity-bearing device material. */
export function TechnicalMode({ trust }: { trust: TrustMetadata }) {
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
