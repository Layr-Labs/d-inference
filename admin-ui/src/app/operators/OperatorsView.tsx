"use client";

import { InteractiveTable, type ICol } from "@/components/InteractiveTable";
import { CopyButton } from "@/components/CopyButton";
import { formatNumber, formatUSDFromMicro, formatRelative } from "@/lib/format";
import type { OperatorRow } from "@/lib/queries/operators";

const COLUMNS: ICol<OperatorRow>[] = [
  {
    key: "email",
    header: "Operator",
    sortValue: (o) => o.email ?? "",
    render: (o) => (
      <span className="inline-flex items-center gap-1.5">
        {o.email}
        <CopyButton text={o.email} title="Copy email" />
      </span>
    ),
  },
  {
    key: "machines",
    header: "Machines",
    align: "right",
    sortValue: (o) => o.machines,
    render: (o) => formatNumber(o.machines),
  },
  {
    key: "online",
    header: "Online",
    align: "right",
    sortValue: (o) => o.online,
    render: (o) => (
      <span style={{ color: o.online > 0 ? "var(--green)" : "var(--text-faint)" }}>
        {formatNumber(o.online)}
      </span>
    ),
  },
  {
    key: "ram_gb",
    header: "Total RAM",
    align: "right",
    sortValue: (o) => Number(o.ram_gb ?? 0),
    render: (o) => `${formatNumber(o.ram_gb)} GB`,
  },
  {
    key: "reqs",
    header: "Lifetime reqs",
    align: "right",
    sortValue: (o) => Number(o.reqs ?? 0),
    render: (o) => formatNumber(o.reqs),
  },
  {
    key: "models",
    header: "Models",
    align: "right",
    sortValue: (o) => o.models.length,
    render: (o) =>
      o.models.length ? (
        <span title={o.models.join(", ")}>{formatNumber(o.models.length)}</span>
      ) : (
        "—"
      ),
  },
  {
    key: "balance_micro_usd",
    header: "Balance",
    align: "right",
    sortValue: (o) => Number(o.balance_micro_usd ?? 0),
    render: (o) => formatUSDFromMicro(o.balance_micro_usd),
  },
  {
    key: "last_seen",
    header: "Last seen",
    sortValue: (o) => o.last_seen,
    render: (o) => formatRelative(o.last_seen),
  },
  { key: "account_id", header: "Account ID", mono: true },
];

export function OperatorsView({ rows }: { rows: OperatorRow[] }) {
  return (
    <InteractiveTable
      rows={rows}
      columns={COLUMNS}
      searchText={(o) => `${o.email} ${o.models.join(" ")}`}
      searchPlaceholder="Filter by email or model…"
      copyField={(o) => o.email}
      copyLabel="Copy operator emails"
      empty="No operators."
    />
  );
}
