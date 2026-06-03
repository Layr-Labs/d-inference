import type { ReactNode } from "react";
import {
  getMachineBySerial,
  getMachineReputation,
  getRecentUsageForProvider,
  type ProviderUsageRow,
} from "@/lib/queries/machine";
import { getMachineSessions, type SessionRow } from "@/lib/queries/sessions";
import { isUndefinedTable } from "@/lib/db";
import { DataTable, type Column } from "@/components/DataTable";
import {
  formatNumber,
  formatUSDFromMicro,
  formatDateTime,
  formatRelative,
  formatDuration,
  isOnline,
  truncate,
} from "@/lib/format";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

function OnlineBadge({ lastSeen }: { lastSeen: string }) {
  const online = isOnline(lastSeen);
  return (
    <span
      className="inline-flex items-center gap-1.5 text-xs"
      style={{ color: online ? "var(--green)" : "var(--text-faint)" }}
    >
      <span
        className="inline-block h-2 w-2 rounded-full"
        style={{ background: online ? "var(--green)" : "var(--text-faint)" }}
      />
      {online ? "online" : "offline"}
    </span>
  );
}

function BoolBadge({ value }: { value: boolean }) {
  return (
    <span style={{ color: value ? "var(--green)" : "var(--text-faint)" }}>
      {value ? "yes" : "no"}
    </span>
  );
}

// A labelled key/value grid. Keeps each section consistent and presentational.
function Section({ title, children }: { title: string; children: ReactNode }) {
  return (
    <section className="space-y-2">
      <h2 className="text-sm font-medium text-[var(--text-dim)] uppercase tracking-wide">
        {title}
      </h2>
      <div className="overflow-x-auto rounded-lg border border-[var(--border)]">
        <table className="w-full border-collapse text-left text-sm">
          <tbody>{children}</tbody>
        </table>
      </div>
    </section>
  );
}

function Row({ label, value, mono }: { label: string; value: ReactNode; mono?: boolean }) {
  return (
    <tr className="border-t border-[var(--border)] first:border-t-0">
      <td className="w-56 px-3 py-2 align-top text-[var(--text-dim)]">{label}</td>
      <td className={`px-3 py-2 align-top ${mono ? "mono" : ""}`}>{value}</td>
    </tr>
  );
}

const SESSION_COLUMNS: Column<SessionRow>[] = [
  {
    key: "status",
    header: "Status",
    render: (s) =>
      s.disconnected_at === null ? (
        <span style={{ color: "var(--green)" }}>● open</span>
      ) : (
        <span className="text-[var(--text-faint)]">ended</span>
      ),
  },
  { key: "connected_at", header: "Connected", render: (s) => formatDateTime(s.connected_at) },
  {
    key: "duration_seconds",
    header: "Duration",
    align: "right",
    render: (s) => formatDuration(s.duration_seconds),
  },
  { key: "last_seen", header: "Last seen", render: (s) => formatRelative(s.last_seen) },
  {
    key: "disconnect_reason",
    header: "Ended",
    render: (s) =>
      s.disconnected_at === null
        ? "—"
        : `${formatRelative(s.disconnected_at)} (${s.disconnect_reason || "?"})`,
  },
];

const USAGE_COLUMNS: Column<ProviderUsageRow>[] = [
  { key: "created_at", header: "Time", render: (u) => formatRelative(u.created_at) },
  { key: "model", header: "Model", render: (u) => u.model || "—" },
  {
    key: "tokens",
    header: "Tokens",
    align: "right",
    render: (u) =>
      `${formatNumber(u.prompt_tokens)} / ${formatNumber(u.completion_tokens)}`,
  },
  {
    key: "cost_micro_usd",
    header: "Cost",
    align: "right",
    render: (u) => formatUSDFromMicro(u.cost_micro_usd),
  },
];

export default async function MachineDetailPage({
  params,
}: {
  params: Promise<{ serial: string }>;
}) {
  const { serial } = await params;

  const machine = await getMachineBySerial(serial);
  if (!machine) {
    return (
      <div className="space-y-4">
        <h1 className="text-lg font-semibold">Machine not found</h1>
        <p className="text-sm text-[var(--text-dim)]">
          No provider session exists for serial{" "}
          <span className="mono">{serial}</span>.
        </p>
      </div>
    );
  }

  const [reputation, usage] = await Promise.all([
    getMachineReputation(machine.id),
    getRecentUsageForProvider(machine.id, 20),
  ]);

  // Session history is tolerant of the provider_sessions table not existing yet
  // (it only appears after a coordinator deploy with session capture).
  let sessions: SessionRow[] = [];
  let sessionsNotDeployed = false;
  try {
    sessions = await getMachineSessions(serial, 50);
  } catch (err) {
    if (!isUndefinedTable(err)) throw err;
    sessionsNotDeployed = true;
  }

  const hw = machine.hardware ?? {};

  return (
    <div className="space-y-6">
      <header className="space-y-1">
        <div className="flex items-center gap-3">
          <h1 className="mono text-lg font-semibold">{machine.serial_number}</h1>
          <OnlineBadge lastSeen={machine.last_seen} />
        </div>
        <p className="text-sm text-[var(--text-dim)]">
          Owner:{" "}
          {machine.email ?? (
            <span className="text-[var(--text-faint)]">unlinked</span>
          )}
          {" · "}Last seen {formatRelative(machine.last_seen)}
          {" · "}Registered {formatDateTime(machine.registered_at)}
        </p>
      </header>

      <Section title="Hardware">
        <Row label="Chip" value={hw.chip_name || "—"} />
        <Row label="Chip family" value={hw.chip_family || "—"} />
        <Row label="Chip tier" value={hw.chip_tier || "—"} />
        <Row
          label="CPU cores"
          value={hw.cpu_cores?.total == null ? "—" : formatNumber(hw.cpu_cores.total)}
        />
        <Row
          label="GPU cores"
          value={hw.gpu_cores == null ? "—" : formatNumber(hw.gpu_cores)}
        />
        <Row
          label="Memory"
          value={hw.memory_gb == null ? "—" : `${formatNumber(hw.memory_gb)} GB`}
        />
        <Row
          label="Memory bandwidth"
          value={
            hw.memory_bandwidth_gbs == null
              ? "—"
              : `${formatNumber(hw.memory_bandwidth_gbs)} GB/s`
          }
        />
        <Row label="Machine model" value={hw.machine_model || "—"} />
      </Section>

      <Section title="Trust & attestation">
        <Row label="Trust level" value={machine.trust_level || "—"} />
        <Row label="Attested" value={<BoolBadge value={machine.attested} />} />
        <Row label="MDA verified" value={<BoolBadge value={machine.mda_verified} />} />
        <Row label="ACME verified" value={<BoolBadge value={machine.acme_verified} />} />
        <Row
          label="Runtime verified"
          value={<BoolBadge value={machine.runtime_verified} />}
        />
        <Row label="Failed challenges" value={formatNumber(machine.failed_challenges)} />
        <Row
          label="SE public key"
          mono
          value={
            machine.se_public_key ? (
              <span title={machine.se_public_key}>{truncate(machine.se_public_key, 24)}</span>
            ) : (
              "—"
            )
          }
        />
        <Row
          label="Last challenge verified"
          value={
            machine.last_challenge_verified
              ? formatDateTime(machine.last_challenge_verified)
              : "—"
          }
        />
        <Row label="Backend" value={machine.backend || "—"} />
        <Row label="Version" mono value={machine.version || "—"} />
      </Section>

      <Section title="Reputation">
        {reputation ? (
          <>
            <Row label="Total jobs" value={formatNumber(reputation.total_jobs)} />
            <Row label="Successful jobs" value={formatNumber(reputation.successful_jobs)} />
            <Row label="Failed jobs" value={formatNumber(reputation.failed_jobs)} />
            <Row
              label="Avg response time"
              value={`${formatNumber(reputation.avg_response_time_ms)} ms`}
            />
            <Row
              label="Challenges passed"
              value={formatNumber(reputation.challenges_passed)}
            />
            <Row
              label="Challenges failed"
              value={formatNumber(reputation.challenges_failed)}
            />
          </>
        ) : (
          <Row
            label="—"
            value={<span className="text-[var(--text-faint)]">No reputation data yet.</span>}
          />
        )}
      </Section>

      <Section title="Lifetime / last session">
        <Row
          label="Lifetime requests"
          value={formatNumber(machine.lifetime_requests_served)}
        />
        <Row
          label="Lifetime tokens"
          value={formatNumber(machine.lifetime_tokens_generated)}
        />
        <Row
          label="Last session requests"
          value={formatNumber(machine.last_session_requests_served)}
        />
        <Row
          label="Last session tokens"
          value={formatNumber(machine.last_session_tokens_generated)}
        />
      </Section>

      <section className="space-y-2">
        <h2 className="text-sm font-medium text-[var(--text-dim)] uppercase tracking-wide">
          Session history (uptime)
        </h2>
        {sessionsNotDeployed ? (
          <p className="text-sm text-[var(--text-faint)]">
            Session capture not deployed yet — connect/disconnect history will appear here
            once the coordinator records it.
          </p>
        ) : (
          <DataTable
            columns={SESSION_COLUMNS}
            rows={sessions}
            empty="No sessions recorded for this machine yet."
          />
        )}
      </section>

      <section className="space-y-2">
        <h2 className="text-sm font-medium text-[var(--text-dim)] uppercase tracking-wide">
          Models{" "}
          <span className="text-[var(--text-faint)]">({machine.models.length})</span>
        </h2>
        {machine.models.length ? (
          <ul className="space-y-1 text-sm">
            {machine.models.map((m, i) => {
              const id = typeof m.id === "string" ? m.id : JSON.stringify(m);
              return (
                <li key={i} className="mono text-[var(--text-dim)]">
                  {id}
                </li>
              );
            })}
          </ul>
        ) : (
          <p className="text-sm text-[var(--text-faint)]">No models reported.</p>
        )}
      </section>

      <section className="space-y-2">
        <h2 className="text-sm font-medium text-[var(--text-dim)] uppercase tracking-wide">
          Recent usage
        </h2>
        <p className="text-xs text-[var(--text-faint)]">
          Last {usage.length} requests served by this session. Tokens shown as prompt /
          completion.
        </p>
        <DataTable columns={USAGE_COLUMNS} rows={usage} empty="No usage for this session." />
      </section>
    </div>
  );
}
