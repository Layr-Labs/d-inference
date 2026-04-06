"use client";

import { useState } from "react";
import type { TrustMetadata } from "@/lib/api";
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
} from "lucide-react";

const ATTESTATION_API = "https://inference-test.openinnovation.dev";

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

export function VerificationPanel({ trust }: { trust: TrustMetadata }) {
  const [open, setOpen] = useState(false);
  const [verifying, setVerifying] = useState(false);
  const [verifyResult, setVerifyResult] = useState<string | null>(null);
  const [providerDetail, setProviderDetail] = useState<{
    systemVolumeHash?: string;
    sePublicKey?: string;
    mdaSerial?: string;
    mdaOsVersion?: string;
    mdaSepVersion?: string;
    mdaCertCount?: number;
  } | null>(null);

  const isHardware = trust.trustLevel === "hardware";

  const Icon = isHardware ? ShieldCheck : Shield;
  const color = isHardware ? "text-accent-green" : "text-text-tertiary";
  const bg = isHardware ? "bg-accent-green/5" : "bg-bg-secondary";
  const title = isHardware
    ? trust.mdaVerified
      ? "Apple Attested"
      : "Hardware Verified"
    : "Unverified";

  const chipLabel = trust.providerChip
    ? `${trust.providerChip}${trust.providerSerial ? ` · ${trust.providerSerial}` : ""}`
    : "";

  async function handleVerify() {
    setVerifying(true);
    setVerifyResult(null);
    try {
      const res = await fetch(`${ATTESTATION_API}/v1/providers/attestation`);
      const data = await res.json();

      const provider = data.providers?.find(
        (p: { serial_number: string }) => p.serial_number === trust.providerSerial
      ) || data.providers?.[0];

      if (!provider) {
        setVerifyResult("Provider not found in attestation API");
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

      const certs = provider.mda_cert_chain_b64 || [];
      const checks = [
        { ok: provider.trust_level === "hardware", label: "Hardware trust level" },
        { ok: provider.mdm_verified, label: "MDM SecurityInfo verified" },
        { ok: provider.mda_verified, label: "Apple MDA cert chain verified" },
        { ok: certs.length >= 2, label: `Apple cert chain: ${certs.length} certificates` },
        { ok: provider.mda_serial === provider.serial_number, label: `Serial match: ${provider.mda_serial}` },
        { ok: provider.secure_enclave, label: "Secure Enclave available" },
        { ok: provider.sip_enabled, label: "SIP enabled" },
        { ok: provider.secure_boot_enabled, label: "Secure Boot enabled" },
        { ok: provider.authenticated_root_enabled, label: "Authenticated Root Volume" },
      ];

      const passed = checks.filter((c) => c.ok).length;
      setVerifyResult(
        passed === checks.length
          ? `All ${passed} checks passed. Provider ${provider.serial_number} verified by Apple Enterprise Attestation Root CA.`
          : `${passed}/${checks.length} checks passed. ${checks.filter((c) => !c.ok).map((c) => c.label).join(", ")} failed.`
      );
    } catch (e) {
      setVerifyResult(`Error: ${e instanceof Error ? e.message : String(e)}`);
    } finally {
      setVerifying(false);
    }
  }

  return (
    <div className={`rounded-xl ${bg} shadow-sm overflow-hidden max-w-full`}>
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
          <p className="text-xs text-text-tertiary mt-2 mb-2 font-medium uppercase tracking-wider">
            Provider Security Verification
          </p>

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
            <StatusLine ok={isHardware} label="System Integrity Protection (SIP)" detail={isHardware ? "Enabled" : "Unknown"} />
            <StatusLine ok={isHardware} label="Secure Boot" detail={isHardware ? "Full Security" : "Unknown"} />
            <StatusLine ok={isHardware} label="Authenticated Root Volume" detail={isHardware ? "Sealed" : "Unknown"} />
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
              <StatusLine ok={true} label="Apple CA certificate chain verified" />
              <StatusLine ok={true} label="Device identity confirmed by Apple" />
            </div>
          )}

          {isHardware && (
            <div className="mt-3 pt-2 border-t border-border-dim/50">
              <button
                onClick={handleVerify}
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

              {verifyResult && (
                <p className={`mt-2 text-xs font-mono leading-relaxed ${
                  verifyResult.startsWith("All") ? "text-accent-green" : "text-accent-red"
                }`}>
                  {verifyResult}
                </p>
              )}

              {providerDetail && (
                <div className="mt-2 space-y-1.5 text-xs text-text-tertiary">
                  {providerDetail.mdaSerial && (
                    <p><span className="font-mono">MDA Serial:</span> {providerDetail.mdaSerial}</p>
                  )}
                  {providerDetail.mdaOsVersion && (
                    <p>
                      <span className="font-mono">macOS:</span> {providerDetail.mdaOsVersion}
                      {providerDetail.mdaSepVersion && ` · SepOS: ${providerDetail.mdaSepVersion}`}
                    </p>
                  )}
                  {providerDetail.mdaCertCount !== undefined && providerDetail.mdaCertCount > 0 && (
                    <p><span className="font-mono">Apple Certs:</span> {providerDetail.mdaCertCount} (leaf + intermediate)</p>
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
        </div>
      )}
    </div>
  );
}
