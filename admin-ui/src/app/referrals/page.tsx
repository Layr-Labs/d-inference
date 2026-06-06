import {
  listReferrers,
  listInviteCodes,
  type ReferrerRow,
  type InviteCodeRow,
} from "@/lib/queries/referrals";
import { DataTable, type Column } from "@/components/DataTable";
import { formatNumber, formatUSDFromMicro, formatRelative } from "@/lib/format";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

const REFERRER_COLUMNS: Column<ReferrerRow>[] = [
  {
    key: "email",
    header: "Email",
    render: (r) => r.email || <span className="text-[var(--text-faint)]">unlinked</span>,
  },
  { key: "code", header: "Code", mono: true },
  {
    key: "referred_count",
    header: "Referred",
    align: "right",
    render: (r) => formatNumber(r.referred_count),
  },
  { key: "created_at", header: "Created", render: (r) => formatRelative(r.created_at) },
  { key: "account_id", header: "Account ID", mono: true },
];

const INVITE_COLUMNS: Column<InviteCodeRow>[] = [
  { key: "code", header: "Code", mono: true },
  {
    key: "amount_micro_usd",
    header: "Amount",
    align: "right",
    render: (i) => formatUSDFromMicro(i.amount_micro_usd),
  },
  {
    key: "uses",
    header: "Uses",
    align: "right",
    render: (i) => `${formatNumber(i.used_count)} / ${formatNumber(i.max_uses)}`,
  },
  {
    key: "active",
    header: "Active",
    align: "right",
    render: (i) =>
      i.active ? (
        <span style={{ color: "var(--green)" }}>✓</span>
      ) : (
        <span className="text-[var(--text-faint)]">✗</span>
      ),
  },
  {
    key: "expires_at",
    header: "Expires",
    render: (i) =>
      i.expires_at ? formatRelative(i.expires_at) : <span className="text-[var(--text-faint)]">never</span>,
  },
  { key: "created_at", header: "Created", render: (i) => formatRelative(i.created_at) },
];

export default async function ReferralsPage() {
  const [referrers, inviteCodes] = await Promise.all([listReferrers(200), listInviteCodes(200)]);
  return (
    <div className="space-y-8">
      <section className="space-y-4">
        <h1 className="text-lg font-semibold">
          Referrers <span className="text-[var(--text-faint)]">({formatNumber(referrers.length)})</span>
        </h1>
        <p className="text-sm text-[var(--text-dim)]">
          Most recent 200, newest first. &ldquo;Referred&rdquo; is the number of accounts each code
          has brought in.
        </p>
        <DataTable columns={REFERRER_COLUMNS} rows={referrers} empty="No referrers." />
      </section>

      <section className="space-y-4">
        <h2 className="text-lg font-semibold">
          Invite codes{" "}
          <span className="text-[var(--text-faint)]">({formatNumber(inviteCodes.length)})</span>
        </h2>
        <p className="text-sm text-[var(--text-dim)]">
          Most recent 200, newest first. Codes grant the listed credit on redemption.
        </p>
        <DataTable columns={INVITE_COLUMNS} rows={inviteCodes} empty="No invite codes." />
      </section>
    </div>
  );
}
