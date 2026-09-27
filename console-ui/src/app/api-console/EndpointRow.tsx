"use client";

import { useId, useState } from "react";
import { ChevronDown, LockKeyhole } from "lucide-react";
import { trackEvent } from "@/lib/google-analytics";
import type { Endpoint } from "./content";

export function EndpointRow({ method, path, description, auth, request, response, notes }: Endpoint) {
  const [expanded, setExpanded] = useState(false);
  const detailsId = useId();

  return (
    <div className="border-b border-border-dim last:border-0">
      <button
        type="button"
        aria-expanded={expanded}
        aria-controls={detailsId}
        onClick={() => {
          const nextExpanded = !expanded;
          setExpanded(nextExpanded);
          if (nextExpanded) trackEvent("api_endpoint_expanded", { endpoint_path: path, http_method: method, requires_auth: auth });
        }}
        className="group flex w-full items-start gap-3 py-4 text-left transition-colors hover:bg-bg-hover/50 sm:items-center sm:px-3"
      >
        <span className={`mt-0.5 w-12 shrink-0 rounded py-1 text-center font-mono text-[11px] font-medium sm:mt-0 ${method === "GET" ? "bg-accent-green/10 text-accent-green" : "bg-accent-brand/8 text-accent-brand"}`}>{method}</span>
        <span className="min-w-0 flex-1">
          <span className="block break-all font-mono text-sm text-text-primary">{path}</span>
          <span className="mt-1.5 block text-xs leading-relaxed text-text-secondary">{description}</span>
        </span>
        {auth && <LockKeyhole size={13} className="mt-2 shrink-0 text-text-secondary sm:mt-0" aria-label="Authentication required" />}
        <ChevronDown size={16} className={`mt-1.5 shrink-0 text-text-secondary transition-transform sm:mt-0 ${expanded ? "rotate-180" : ""}`} />
      </button>
      <div id={detailsId} hidden={!expanded} className="space-y-4 pb-5 pt-1 sm:pl-[4.5rem] sm:pr-3">
        {auth && <p className="text-xs leading-relaxed text-text-secondary">Requires an <code className="break-all text-text-primary">Authorization: Bearer &lt;api_key&gt;</code> header.</p>}
        {request && <ReferenceCode label="Request" code={request} />}
        {response && <ReferenceCode label="Response" code={response} />}
        {notes && <p className="max-w-3xl text-xs leading-relaxed text-text-secondary">{notes}</p>}
      </div>
    </div>
  );
}

function ReferenceCode({ label, code }: { label: string; code: string }) {
  return (
    <div>
      <p className="mb-2 text-xs font-medium text-text-secondary">{label}</p>
      <pre className="overflow-x-auto whitespace-pre rounded-lg border border-border-dim bg-bg-white p-4 font-mono text-xs leading-relaxed text-text-primary"><code>{code}</code></pre>
    </div>
  );
}
