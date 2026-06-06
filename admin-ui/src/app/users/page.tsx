import { listUsers, countUsers } from "@/lib/queries/users";
import { UsersView } from "./UsersView";
import { formatNumber } from "@/lib/format";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

const USERS_LIMIT = 5000;

export default async function UsersPage() {
  // Match the operator/machine pages' fleet scope so an older account that owns
  // machines isn't unfindable here (it was capped at the 200 newest before).
  const [rows, total] = await Promise.all([listUsers(USERS_LIMIT), countUsers()]);
  const truncated = total > rows.length;
  return (
    <div className="space-y-4">
      <h1 className="text-lg font-semibold">
        Users <span className="text-[var(--text-faint)]">({formatNumber(total)})</span>
      </h1>
      <p className="text-sm text-[var(--text-dim)]">
        {truncated
          ? `Showing the ${formatNumber(rows.length)} newest of ${formatNumber(total)} — older accounts are not listed.`
          : "Newest first."}{" "}
        Filter, click a column to sort, and copy emails.
      </p>
      <UsersView rows={rows} />
    </div>
  );
}
