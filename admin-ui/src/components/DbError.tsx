// Friendly panel shown when a read-only-replica query fails (e.g. ADMIN_DB_URL
// unset, replica recovery conflict, or statement timeout).
//
// Shows a stable digest reference rather than the raw error message: the full
// detail (SQL, connection string fragments, pg internals) stays server-side via
// the console.error in db.ts. In prod Next already redacts error-boundary
// messages to a digest; rendering the digest here is consistent in dev too and
// avoids ever surfacing query internals in the browser.
export function DbError({ digest }: { digest?: string }) {
  return (
    <div className="rounded-lg border border-[var(--red)] bg-[var(--bg-elevated)] p-4">
      <div className="font-medium text-[var(--red)]">Database unavailable</div>
      <div className="mt-1 text-sm text-[var(--text-dim)]">
        Could not query the read-only replica. Check <span className="mono">ADMIN_DB_URL</span>,
        or retry — the replica can briefly cancel long reads (WAL-replay conflict).
        The detailed error is in the server logs.
      </div>
      {digest && (
        <pre className="mono mt-2 overflow-x-auto text-xs text-[var(--text-faint)]">
          Reference: {digest}
        </pre>
      )}
    </div>
  );
}
