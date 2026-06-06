import "server-only";
import { query } from "@/lib/db";

export interface ModelRow {
  id: string;
  display_name: string;
  family: string;
  architecture: string;
  quantization: string;
  status: string;
  description: string;
  min_ram_gb: number | null;
  max_context_length: number | null;
  max_output_length: number | null;
  capabilities: string[];
  active_version: string | null;
  total_size_bytes: string | null;
  file_count: number | null;
  aggregate_sha256: string | null;
  // Platform pricing, micro-USD per 1M tokens (null = uses the coordinator
  // default fallback). BIGINT → string from pg.
  input_price_micro: string | null;
  output_price_micro: string | null;
  created_at: string;
  updated_at: string;
}

// Coordinator fallback when a model has no platform price row
// (payments.DefaultInputPricePerMillion / DefaultOutputPricePerMillion).
export const DEFAULT_INPUT_PRICE_MICRO = 50_000;
export const DEFAULT_OUTPUT_PRICE_MICRO = 200_000;

// All registered models, joined to their active version + that version's size.
// LEFT JOINs so models without an active/ready version still show (size "—").
// capabilities (TEXT[]) comes back from pg as a JS string array.
export async function listModels(limit = 200): Promise<ModelRow[]> {
  const rows = await query<
    Omit<ModelRow, "min_ram_gb" | "file_count" | "capabilities"> & {
      min_ram_gb: string | null;
      file_count: string | null;
      capabilities: string[] | null;
    }
  >(
    `SELECT mr.id,
            mr.display_name,
            mr.family,
            mr.architecture,
            mr.quantization,
            mr.status,
            mr.description,
            mr.min_ram_gb,
            mr.max_context_length,
            mr.max_output_length,
            mr.capabilities,
            mv.version           AS active_version,
            mv.total_size_bytes,
            mv.file_count,
            mv.aggregate_sha256,
            mp.input_price       AS input_price_micro,
            mp.output_price      AS output_price_micro,
            mr.created_at,
            mr.updated_at
       FROM model_registry mr
       LEFT JOIN model_active_versions mav ON mav.model_id = mr.id
       LEFT JOIN model_versions mv ON mv.id = mav.model_version_id
       LEFT JOIN model_prices mp ON mp.account_id = 'platform' AND mp.model = mr.id
      ORDER BY mr.display_name ASC
      LIMIT $1`,
    [limit],
  );
  return rows.map((r) => ({
    ...r,
    min_ram_gb: r.min_ram_gb === null ? null : Number(r.min_ram_gb),
    file_count: r.file_count === null ? null : Number(r.file_count),
    capabilities: r.capabilities ?? [],
  }));
}

export async function countModels(): Promise<number> {
  const [r] = await query<{ n: string }>(`SELECT count(*) AS n FROM model_registry`);
  return Number(r?.n ?? 0);
}
