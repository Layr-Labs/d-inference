import { listUsers, countUsers } from "@/lib/queries/users";
import { UsersView } from "./UsersView";
import { formatNumber } from "@/lib/format";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

export default async function UsersPage() {
  const [rows, total] = await Promise.all([listUsers(200), countUsers()]);
  return (
    <div className="space-y-4">
      <h1 className="text-lg font-semibold">
        Users <span className="text-[var(--text-faint)]">({formatNumber(total)})</span>
      </h1>
      <p className="text-sm text-[var(--text-dim)]">
        Most recent 200, newest first. Filter, click a column to sort, and copy emails.
      </p>
      <UsersView rows={rows} />
    </div>
  );
}
