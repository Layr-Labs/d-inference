import {
  listTopBalances,
  listRecentLedger,
  type BalanceRow,
  type LedgerRow,
} from "@/lib/queries/billing";
import { DataTable, type Column } from "@/components/DataTable";
import { formatUSDFromMicro, formatRelative, truncate } from "@/lib/format";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

const BALANCE_COLUMNS: Column<BalanceRow>[] = [
  {
    key: "email",
    header: "Email",
    render: (b) => b.email || <span className="text-[var(--text-faint)]">unlinked</span>,
  },
  {
    key: "balance_micro_usd",
    header: "Balance",
    align: "right",
    render: (b) => formatUSDFromMicro(b.balance_micro_usd),
  },
  {
    key: "withdrawable_micro_usd",
    header: "Withdrawable",
    align: "right",
    render: (b) => formatUSDFromMicro(b.withdrawable_micro_usd),
  },
  { key: "updated_at", header: "Updated", render: (b) => formatRelative(b.updated_at) },
  { key: "account_id", header: "Account ID", mono: true },
];

const LEDGER_COLUMNS: Column<LedgerRow>[] = [
  { key: "created_at", header: "When", render: (l) => formatRelative(l.created_at) },
  {
    key: "email",
    header: "Email",
    render: (l) => l.email || <span className="text-[var(--text-faint)]">unlinked</span>,
  },
  { key: "entry_type", header: "Type", render: (l) => l.entry_type || "—" },
  {
    key: "amount_micro_usd",
    header: "Amount",
    align: "right",
    render: (l) => formatUSDFromMicro(l.amount_micro_usd),
  },
  {
    key: "balance_after",
    header: "Balance after",
    align: "right",
    render: (l) => formatUSDFromMicro(l.balance_after),
  },
  {
    key: "reference",
    header: "Reference",
    mono: true,
    render: (l) => (l.reference ? truncate(l.reference, 24) : "—"),
  },
];

export default async function BillingPage() {
  const [balances, ledger] = await Promise.all([
    listTopBalances(100),
    listRecentLedger(100),
  ]);
  return (
    <div className="space-y-8">
      <section className="space-y-4">
        <h2 className="text-lg font-semibold">Top balances</h2>
        <p className="text-sm text-[var(--text-dim)]">
          Largest 100 account balances, highest first.
        </p>
        <DataTable columns={BALANCE_COLUMNS} rows={balances} empty="No balances." />
      </section>
      <section className="space-y-4">
        <h2 className="text-lg font-semibold">Recent ledger entries</h2>
        <p className="text-sm text-[var(--text-dim)]">
          Most recent 100 entries, newest first. Amounts are signed (credits
          positive, debits negative).
        </p>
        <DataTable columns={LEDGER_COLUMNS} rows={ledger} empty="No ledger entries." />
      </section>
    </div>
  );
}
