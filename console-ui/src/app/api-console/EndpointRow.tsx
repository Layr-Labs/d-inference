"use client";

import { useState } from "react";
import { ChevronDown } from "lucide-react";
import { trackEvent } from "@/lib/google-analytics";
import type { Endpoint } from "./content";

// One expandable endpoint reference row. The only interactive (client) island
// in the otherwise-static endpoint reference.
export function EndpointRow({
  method,
  path,
  description,
  icon: Icon,
  auth,
  request,
  response,
  notes,
}: Endpoint) {
  const [expanded, setExpanded] = useState(false);

  return (
    <div className="border-b border-border-dim/50 last:border-0">
      <button
        onClick={() => {
          const nextExpanded = !expanded;
          setExpanded(nextExpanded);
          if (nextExpanded) {
            trackEvent("api_endpoint_expanded", {
              endpoint_path: path,
              http_method: method,
              requires_auth: auth,
            });
          }
        }}
        className="w-full flex items-center gap-3 px-4 py-3 text-left hover:bg-bg-hover transition-colors"
      >
        <Icon size={16} className="text-text-tertiary shrink-0" />
        <span
          className={`text-xs font-mono font-bold px-2 py-0.5 rounded ${
            method === "GET"
              ? "bg-blue/10 text-blue"
              : "bg-accent-brand/10 text-accent-brand"
          }`}
        >
          {method}
        </span>
        <span className="text-sm font-mono text-text-primary">{path}</span>
        {auth && (
          <span className="text-xs text-text-tertiary px-1.5 py-0.5 bg-bg-tertiary rounded">
            Auth
          </span>
        )}
        <span className="flex-1 text-xs text-text-tertiary text-right truncate ml-2">
          {description}
        </span>
        <ChevronDown
          size={14}
          className={`text-text-tertiary transition-transform ${expanded ? "rotate-180" : ""}`}
        />
      </button>
      {expanded && (
        <div className="px-4 pb-4 space-y-3">
          <p className="text-sm text-text-secondary">{description}</p>
          {auth && (
            <p className="text-xs text-text-tertiary">
              Requires <code className="text-accent-brand">Authorization: Bearer &lt;api_key&gt;</code> header
            </p>
          )}
          {request && (
            <div>
              <p className="text-xs font-mono text-text-tertiary mb-1.5">Request</p>
              <pre className="bg-bg-primary border border-border-dim rounded-lg px-3 py-2.5 text-xs font-mono text-text-primary overflow-x-auto whitespace-pre">{request}</pre>
            </div>
          )}
          {response && (
            <div>
              <p className="text-xs font-mono text-text-tertiary mb-1.5">Response</p>
              <pre className="bg-bg-primary border border-border-dim rounded-lg px-3 py-2.5 text-xs font-mono text-text-primary overflow-x-auto whitespace-pre">{response}</pre>
            </div>
          )}
          {notes && (
            <p className="text-xs text-text-tertiary leading-relaxed">{notes}</p>
          )}
        </div>
      )}
    </div>
  );
}
