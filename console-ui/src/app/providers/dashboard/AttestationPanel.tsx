"use client";

// The trust chain as a connected vertical ladder: Secure Enclave → OS security
// → MDM posture → Apple Device Attestation. Each link is green when verified
// and dashed/grey where it breaks, so "where is the chain broken" is obvious at
// a glance. Raw Apple certificates and hardware identifiers stay private to
// the provider and coordinator.

import { useEffect, useState } from "react";
import {
  CheckCircle2,
  XCircle,
} from "lucide-react";
import type { MyProvider } from "../types";
import { formatRelative } from "./format";

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

export function AttestationPanel({
  provider: p,
  challengeMaxAgeSeconds,
}: {
  provider: MyProvider;
  challengeMaxAgeSeconds: number;
}) {
  // Each chain link is "ok" only when all of its sub-checks pass; the spine
  // renders green up to the first broken link so the gap is obvious.
  const osOK = p.sip_enabled && p.secure_boot_enabled && p.authenticated_root_enabled && p.runtime_verified;
  const mdmOK = p.trust_level === "hardware";

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

  return (
    <div>
      <ChainNode ok={p.secure_enclave} title="Secure Enclave">
        <CheckLine ok={p.secure_enclave} label="Hardware-bound P-256 identity" />
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

      <ChainNode ok={mdmOK} title="MDM security posture">
        {mdmOK ? (
          <div className="space-y-0.5 text-[11px] font-mono text-text-secondary">
            <div>Device identity verified privately</div>
            {p.mda_os_version && <div>macOS {p.mda_os_version}</div>}
            {p.mda_sepos_version && <div>SEPOS {p.mda_sepos_version}</div>}
          </div>
        ) : (
          <p className="text-xs text-text-tertiary">MDM verification pending.</p>
        )}
      </ChainNode>

      <ChainNode ok={p.mda_verified} title="Apple Device Attestation" last>
        <CheckLine
          ok={p.mda_verified}
          label="Apple CA certificate chain verified by coordinator"
        />
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
