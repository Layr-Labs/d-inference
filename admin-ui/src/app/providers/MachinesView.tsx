"use client";

import Link from "next/link";
import { InteractiveTable, type ICol } from "@/components/InteractiveTable";
import { CopyButton } from "@/components/CopyButton";
import { formatNumber, formatRelative, isOnline } from "@/lib/format";
import type { MachineRow } from "@/lib/queries/providers";

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

const COLUMNS: ICol<MachineRow>[] = [
  {
    key: "status",
    header: "Status",
    sortValue: (m) => (isOnline(m.last_seen) ? 1 : 0),
    render: (m) => <OnlineBadge lastSeen={m.last_seen} />,
  },
  {
    key: "email",
    header: "Owner",
    sortValue: (m) => m.email ?? "",
    render: (m) =>
      m.email ? (
        <span className="inline-flex items-center gap-1.5">
          {m.email}
          <CopyButton text={m.email} title="Copy email" />
        </span>
      ) : (
        <span className="text-[var(--text-faint)]">unlinked</span>
      ),
  },
  {
    key: "provider_id",
    header: "Provider ID",
    mono: true,
    sortValue: (m) => m.provider_id,
    render: (m) => (
      <Link
        href={`/providers/${m.provider_id}`}
        className="text-[var(--accent)] hover:underline"
      >
        {m.provider_id}
      </Link>
    ),
  },
  { key: "chip_name", header: "Chip", sortValue: (m) => m.chip_name ?? "", render: (m) => m.chip_name || "—" },
  {
    key: "memory_gb",
    header: "RAM",
    align: "right",
    sortValue: (m) => m.memory_gb ?? 0,
    render: (m) => (m.memory_gb == null ? "—" : `${m.memory_gb} GB`),
  },
  {
    key: "model_ids",
    header: "Models",
    render: (m) => (m.model_ids.length ? m.model_ids.join(", ") : "—"),
  },
  { key: "trust_level", header: "Trust", sortValue: (m) => m.trust_level, render: (m) => m.trust_level || "—" },
  { key: "version", header: "Version", mono: true, sortValue: (m) => m.version, render: (m) => m.version || "—" },
  {
    key: "lifetime_requests_served",
    header: "Lifetime reqs",
    align: "right",
    sortValue: (m) => Number(m.lifetime_requests_served ?? 0),
    render: (m) => formatNumber(m.lifetime_requests_served),
  },
  {
    key: "last_seen",
    header: "Last seen",
    sortValue: (m) => m.last_seen,
    render: (m) => formatRelative(m.last_seen),
  },
];

export function MachinesView({ rows }: { rows: MachineRow[] }) {
  return (
    <InteractiveTable
      rows={rows}
      columns={COLUMNS}
      searchText={(m) =>
        `${m.email ?? ""} ${m.provider_id} ${m.chip_name ?? ""} ${m.trust_level} ${m.model_ids.join(" ")}`
      }
      searchPlaceholder="Filter by email, provider ID, chip, model…"
      copyField={(m) => m.email}
      copyLabel="Copy owner emails"
      empty="No machines."
    />
  );
}
