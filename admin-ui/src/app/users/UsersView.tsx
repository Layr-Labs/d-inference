"use client";

import { InteractiveTable, type ICol } from "@/components/InteractiveTable";
import { CopyButton } from "@/components/CopyButton";
import { formatNumber, formatUSDFromMicro, formatRelative } from "@/lib/format";
import type { UserRow } from "@/lib/queries/users";

const COLUMNS: ICol<UserRow>[] = [
  {
    key: "email",
    header: "Email",
    sortValue: (u) => u.email ?? "",
    render: (u) =>
      u.email ? (
        <span className="inline-flex items-center gap-1.5">
          {u.email}
          <CopyButton text={u.email} title="Copy email" />
        </span>
      ) : (
        <span className="text-[var(--text-faint)]">—</span>
      ),
  },
  { key: "role", header: "Role", sortValue: (u) => u.role, render: (u) => u.role || "—" },
  {
    key: "machine_count",
    header: "Machines",
    align: "right",
    sortValue: (u) => u.machine_count,
    render: (u) => formatNumber(u.machine_count),
  },
  {
    key: "balance_micro_usd",
    header: "Balance",
    align: "right",
    sortValue: (u) => Number(u.balance_micro_usd ?? 0),
    render: (u) => formatUSDFromMicro(u.balance_micro_usd),
  },
  {
    key: "platform_fee_percent",
    header: "Fee %",
    align: "right",
    render: (u) => (u.platform_fee_percent == null ? "default" : String(u.platform_fee_percent)),
  },
  {
    key: "created_at",
    header: "Created",
    sortValue: (u) => u.created_at,
    render: (u) => formatRelative(u.created_at),
  },
  { key: "account_id", header: "Account ID", mono: true },
];

export function UsersView({ rows }: { rows: UserRow[] }) {
  return (
    <InteractiveTable
      rows={rows}
      columns={COLUMNS}
      searchText={(u) => `${u.email} ${u.role} ${u.account_id}`}
      searchPlaceholder="Filter by email, role, account…"
      copyField={(u) => u.email}
      copyLabel="Copy emails"
      empty="No users."
    />
  );
}
