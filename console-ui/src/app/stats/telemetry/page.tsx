"use client";

import { useCallback, useEffect, useMemo, useState } from "react";
import { useAuth } from "@/hooks/useAuth";
import { emit } from "@/lib/telemetry";
import type {
  TelemetryEvent,
  TelemetryKind,
  TelemetrySeverity,
  TelemetrySource,
} from "@/lib/telemetry-types";

// Admin-only. The coordinator returns 403 for non-admin Privy users, so
// there's no client-side gate needed — we just render the coordinator's
// response. The useAuth hook supplies the Privy access token.

type Filters = {
  source: TelemetrySource | "";
  severity: TelemetrySeverity | "";
  kind: TelemetryKind | "";
  limit: number;
};

const EMPTY: Filters = {
  source: "",
  severity: "",
  kind: "",
  limit: 100,
};

export default function TelemetryAdminPage() {
  const { ready, authenticated, login } = useAuth();
  const [filters, setFilters] = useState<Filters>(EMPTY);
  const [events, setEvents] = useState<TelemetryEvent[]>([]);
  const [summary, setSummary] = useState<
    Array<{ source: string; severity: string; kind: string; count: number }>
  >([]);
  const [status, setStatus] = useState<"idle" | "loading" | "error" | "forbidden">("idle");
  const [errorMsg, setErrorMsg] = useState<string>("");

  // Read the API key that useAuth provisioned into localStorage. Admin
  // authorization is enforced coordinator-side; we just pass the bearer.
  const fetchToken = useCallback(async () => {
    if (typeof window !== "undefined") {
      return localStorage.getItem("darkbloom_api_key");
    }
    return null;
  }, []);

  const load = useCallback(async () => {
    setStatus("loading");
    setErrorMsg("");
    try {
      const token = await fetchToken();
      const headers: Record<string, string> = {};
      if (token) headers["Authorization"] = `Bearer ${token}`;

      const params = new URLSearchParams();
      if (filters.source) params.set("source", filters.source);
      if (filters.severity) params.set("severity", filters.severity);
      if (filters.kind) params.set("kind", filters.kind);
      params.set("limit", String(filters.limit));

      const [listRes, summaryRes] = await Promise.all([
        fetch(`/api/admin/telemetry?${params.toString()}`, { headers }),
        fetch(`/api/admin/telemetry/summary?window=24h`, { headers }),
      ]);

      if (listRes.status === 403 || summaryRes.status === 403) {
        setStatus("forbidden");
        return;
      }
      if (!listRes.ok) {
        setStatus("error");
        setErrorMsg(`list ${listRes.status}`);
        return;
      }

      const listData = (await listRes.json()) as { events: TelemetryEvent[] };
      setEvents(listData.events || []);
      if (summaryRes.ok) {
        const s = (await summaryRes.json()) as {
          counts: Array<{ source: string; severity: string; kind: string; count: number }>;
        };
        setSummary(s.counts || []);
      }
      setStatus("idle");
    } catch (e) {
      setStatus("error");
      setErrorMsg(e instanceof Error ? e.message : String(e));
      emit({
        kind: "http_error",
        severity: "warn",
        message: "telemetry admin page fetch failed",
        fields: { route: "/stats/telemetry" },
      });
    }
  }, [filters, fetchToken]);

  useEffect(() => {
    if (ready && authenticated) {
      void load();
    }
  }, [ready, authenticated, load]);

  const severityColor = useMemo(
    () => ({
      fatal: "#ff3b30",
      error: "#ff9500",
      warn: "#ffcc00",
      info: "#34c759",
      debug: "#8e8e93",
    }),
    []
  );

  if (!ready) return <Page><p>Loading…</p></Page>;
  if (!authenticated) {
    return (
      <Page>
        <p>Sign in to view telemetry.</p>
        <button onClick={() => login()}>Sign in</button>
      </Page>
    );
  }

  return (
    <Page>
      <header style={{ display: "flex", justifyContent: "space-between", alignItems: "center" }}>
        <h1 style={{ fontSize: "1.5rem", fontWeight: 600 }}>Telemetry</h1>
        <button onClick={() => void load()} disabled={status === "loading"}>
          Refresh
        </button>
      </header>

      {status === "forbidden" && (
        <div style={{ padding: "1rem", background: "#2b1010", borderRadius: "0.5rem" }}>
          Admin access required.
        </div>
      )}

      {status === "error" && <p style={{ color: "#ff9500" }}>{errorMsg}</p>}

      {summary.length > 0 && (
        <section style={{ marginTop: "1rem" }}>
          <h2 style={{ fontSize: "1rem", fontWeight: 500, opacity: 0.8 }}>Last 24h rollup</h2>
          <div style={{ display: "grid", gridTemplateColumns: "repeat(auto-fill, minmax(200px, 1fr))", gap: "0.5rem", marginTop: "0.5rem" }}>
            {summary.slice(0, 12).map((s, i) => (
              <div
                key={`${s.source}-${s.severity}-${s.kind}-${i}`}
                style={{
                  padding: "0.75rem",
                  background: "rgba(255,255,255,0.04)",
                  borderRadius: "0.5rem",
                  border: "1px solid rgba(255,255,255,0.08)",
                }}
              >
                <div style={{ fontSize: "0.75rem", opacity: 0.6, textTransform: "uppercase" }}>
                  {s.source} · {s.kind}
                </div>
                <div style={{ fontSize: "1.25rem", fontWeight: 600, marginTop: "0.25rem" }}>
                  {s.count}
                </div>
                <div
                  style={{
                    fontSize: "0.75rem",
                    color:
                      severityColor[s.severity as keyof typeof severityColor] || "#8e8e93",
                  }}
                >
                  {s.severity}
                </div>
              </div>
            ))}
          </div>
        </section>
      )}

      <section style={{ marginTop: "1.5rem" }}>
        <div style={{ display: "flex", gap: "0.5rem", flexWrap: "wrap", marginBottom: "1rem" }}>
          <Select
            label="Source"
            value={filters.source}
            onChange={(v) => setFilters((f) => ({ ...f, source: v as Filters["source"] }))}
            options={["", "coordinator", "provider", "app", "console", "bridge"]}
          />
          <Select
            label="Severity"
            value={filters.severity}
            onChange={(v) => setFilters((f) => ({ ...f, severity: v as Filters["severity"] }))}
            options={["", "debug", "info", "warn", "error", "fatal"]}
          />
          <Select
            label="Kind"
            value={filters.kind}
            onChange={(v) => setFilters((f) => ({ ...f, kind: v as Filters["kind"] }))}
            options={[
              "",
              "panic",
              "http_error",
              "protocol_error",
              "backend_crash",
              "attestation_failure",
              "inference_error",
              "runtime_mismatch",
              "connectivity",
              "log",
              "custom",
            ]}
          />
        </div>

        <table style={{ width: "100%", fontSize: "0.875rem", borderCollapse: "collapse" }}>
          <thead>
            <tr style={{ textAlign: "left", opacity: 0.7 }}>
              <th style={th}>Time</th>
              <th style={th}>Sev</th>
              <th style={th}>Src</th>
              <th style={th}>Kind</th>
              <th style={th}>Message</th>
              <th style={th}>Machine</th>
            </tr>
          </thead>
          <tbody>
            {events.map((e) => (
              <tr key={e.id} style={{ borderTop: "1px solid rgba(255,255,255,0.06)" }}>
                <td style={td}>{e.timestamp.slice(11, 19)}</td>
                <td
                  style={{
                    ...td,
                    color:
                      severityColor[e.severity as keyof typeof severityColor] || "#8e8e93",
                    fontWeight: 600,
                  }}
                >
                  {e.severity}
                </td>
                <td style={td}>{e.source}</td>
                <td style={td}>{e.kind}</td>
                <td style={{ ...td, fontFamily: "monospace" }}>
                  <details>
                    <summary style={{ cursor: "pointer" }}>{e.message}</summary>
                    {e.fields && Object.keys(e.fields).length > 0 && (
                      <pre style={codeBlock}>{JSON.stringify(e.fields, null, 2)}</pre>
                    )}
                    {e.stack && <pre style={codeBlock}>{e.stack}</pre>}
                  </details>
                </td>
                <td style={{ ...td, opacity: 0.6, fontFamily: "monospace" }}>
                  {(e.machine_id || "").slice(0, 16)}
                </td>
              </tr>
            ))}
          </tbody>
        </table>

        {events.length === 0 && status !== "loading" && status !== "forbidden" && (
          <p style={{ opacity: 0.6, marginTop: "1rem" }}>No events match the filter.</p>
        )}
      </section>
    </Page>
  );
}

const th: React.CSSProperties = { padding: "0.5rem", fontWeight: 500 };
const td: React.CSSProperties = { padding: "0.5rem", verticalAlign: "top" };
const codeBlock: React.CSSProperties = {
  background: "rgba(0,0,0,0.4)",
  padding: "0.5rem",
  borderRadius: "0.25rem",
  fontSize: "0.75rem",
  maxWidth: "800px",
  overflow: "auto",
  marginTop: "0.5rem",
};

function Page({ children }: { children: React.ReactNode }) {
  return (
    <div style={{ padding: "1.5rem 2rem", maxWidth: "1400px", margin: "0 auto" }}>
      {children}
    </div>
  );
}

function Select({
  label,
  value,
  onChange,
  options,
}: {
  label: string;
  value: string;
  onChange: (v: string) => void;
  options: string[];
}) {
  return (
    <label style={{ display: "flex", flexDirection: "column", fontSize: "0.75rem", gap: "0.25rem" }}>
      <span style={{ opacity: 0.6 }}>{label}</span>
      <select
        value={value}
        onChange={(e) => onChange(e.target.value)}
        style={{
          background: "rgba(255,255,255,0.06)",
          border: "1px solid rgba(255,255,255,0.12)",
          borderRadius: "0.25rem",
          padding: "0.375rem 0.5rem",
          color: "inherit",
          minWidth: "140px",
        }}
      >
        {options.map((o) => (
          <option key={o} value={o}>
            {o || "any"}
          </option>
        ))}
      </select>
    </label>
  );
}
