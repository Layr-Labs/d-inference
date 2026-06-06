import "server-only";
import { query } from "@/lib/db";

export interface ReleaseRow {
  version: string;
  platform: string;
  backend: string;
  binary_hash: string;
  bundle_hash: string;
  metallib_hash: string;
  python_hash: string;
  runtime_hash: string;
  grpc_binary_hash: string;
  url: string;
  changelog: string;
  active: boolean;
  created_at: string;
}

// Provider binary releases (PK version,platform). Newest first.
// Hashes here are SHA-256 integrity digests of public release artifacts,
// not credentials, so they are safe to render.
export async function listReleases(limit = 200, offset = 0): Promise<ReleaseRow[]> {
  return query<ReleaseRow>(
    `SELECT version,
            platform,
            COALESCE(backend, '')          AS backend,
            COALESCE(binary_hash, '')      AS binary_hash,
            COALESCE(bundle_hash, '')      AS bundle_hash,
            COALESCE(metallib_hash, '')    AS metallib_hash,
            COALESCE(python_hash, '')      AS python_hash,
            COALESCE(runtime_hash, '')     AS runtime_hash,
            COALESCE(grpc_binary_hash, '') AS grpc_binary_hash,
            COALESCE(url, '')              AS url,
            COALESCE(changelog, '')        AS changelog,
            active,
            created_at
       FROM releases
      ORDER BY created_at DESC
      LIMIT $1 OFFSET $2`,
    [limit, offset],
  );
}

export async function countReleases(): Promise<number> {
  const [r] = await query<{ n: string }>(`SELECT count(*) AS n FROM releases`);
  return Number(r?.n ?? 0);
}
