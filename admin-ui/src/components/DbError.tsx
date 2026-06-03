// Friendly panel shown when a read-only-replica query fails (e.g. ADMIN_DB_URL
// unset, replica recovery conflict, or statement timeout).
export function DbError({ err }: { err: unknown }) {
  return (
    <div className="rounded-lg border border-[var(--red)] bg-[var(--bg-elevated)] p-4">
      <div className="font-medium text-[var(--red)]">Database unavailable</div>
      <div className="mt-1 text-sm text-[var(--text-dim)]">
        Could not query the read-only replica. Check <span className="mono">ADMIN_DB_URL</span>,
        or retry — the replica can briefly cancel long reads (WAL-replay conflict).
      </div>
      <pre className="mono mt-2 overflow-x-auto text-xs text-[var(--text-faint)]">
        {err instanceof Error ? err.message : String(err)}
      </pre>
    </div>
  );
}
