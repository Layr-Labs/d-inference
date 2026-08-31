import { Client } from "pg";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import {
  CAPACITY_SHED_REASONS,
  LATENCY_SHED_REASONS,
  SUPPLY_SHED_REASONS,
  TRACKED_SUPPLY_REASONS,
} from "../supply-pressure";
import { SUPPLY_PRESSURE_SQL } from "./supply-sql";

const databaseURL = process.env.ADMIN_TEST_DATABASE_URL ?? "";
const describeWithPostgres = databaseURL ? describe : describe.skip;

interface SupplyQueryRow {
  model: string;
  display_name: string | null;
  min_ram_gb: number | null;
  supply_rejects_1h: string;
  supply_rejects_24h: string;
  capacity_sheds_1h: string;
  capacity_sheds_24h: string;
  latency_sheds_1h: string;
  unavailable_sheds_1h: string;
  hardware_mismatches_1h: string;
  served_24h: string;
  actual_ttft_p95_ms_1h: number | null;
  actual_ttft_p95_ms_24h: number | null;
  rejected_ttft_p95_ms_1h: number | null;
}

describeWithPostgres("supply-pressure PostgreSQL query", () => {
  const client = new Client({ connectionString: databaseURL, ssl: false });

  beforeAll(async () => {
    await client.connect();
    await client.query(`
      CREATE TEMP TABLE request_rejections (
        requested_model TEXT,
        resolved_model TEXT,
        reason_code TEXT,
        best_ttft_ms DOUBLE PRECISION,
        self_route_only BOOLEAN,
        created_at TIMESTAMPTZ NOT NULL
      );
      CREATE TEMP TABLE inference_routes (
        model TEXT NOT NULL,
        final_status TEXT NOT NULL,
        actual_ttft_ms DOUBLE PRECISION,
        self_route_only BOOLEAN NOT NULL DEFAULT FALSE,
        created_at TIMESTAMPTZ NOT NULL
      );
      CREATE TEMP TABLE model_registry (
        id TEXT PRIMARY KEY,
        display_name TEXT NOT NULL,
        min_ram_gb INTEGER NOT NULL
      );

      INSERT INTO model_registry (id, display_name, min_ram_gb) VALUES
        ('model-a', 'Model A', 64),
        ('model-b', 'Model B', 32);

      INSERT INTO request_rejections
        (requested_model, resolved_model, reason_code, best_ttft_ms, self_route_only, created_at)
      VALUES
        ('model-a', 'model-a', 'capacity_exhausted', NULL, FALSE, now() - interval '10 minutes'),
        ('model-a', 'model-a', 'queue_full', NULL, FALSE, now() - interval '2 hours'),
        ('model-a', 'model-a', 'deadline_unreachable', 4000, FALSE, now() - interval '20 minutes'),
        ('model-a', 'model-a', 'model_too_large', NULL, FALSE, now() - interval '30 minutes'),
        ('model-a', 'model-a', 'queue_full', NULL, TRUE, now() - interval '5 minutes'),
        ('oversized-only', 'oversized-only', 'oversized_request', NULL, FALSE, now() - interval '5 minutes'),
        ('model-b', 'model-b', 'no_provider', NULL, FALSE, now() - interval '15 minutes'),
        ('expired', 'expired', 'queue_full', NULL, FALSE, now() - interval '25 hours');

      INSERT INTO inference_routes
        (model, final_status, actual_ttft_ms, self_route_only, created_at)
      VALUES
        ('model-a', 'success', 100, FALSE, now() - interval '10 minutes'),
        ('model-a', 'partial_success', 300, FALSE, now() - interval '20 minutes'),
        ('model-a', 'success', 500, FALSE, now() - interval '2 hours'),
        ('model-a', 'error', 9000, FALSE, now() - interval '5 minutes'),
        ('model-a', 'success', 8000, TRUE, now() - interval '5 minutes'),
        ('model-b', 'success', 200, FALSE, now() - interval '5 minutes'),
        ('self-only', 'success', 700, TRUE, now() - interval '5 minutes'),
        ('expired', 'success', 600, FALSE, now() - interval '25 hours');
    `);
  });

  afterAll(async () => {
    await client.end();
  });

  it("aggregates public supply rejects and successful route TTFT", async () => {
    const result = await client.query<SupplyQueryRow>(SUPPLY_PRESSURE_SQL, [
      [...CAPACITY_SHED_REASONS],
      [...LATENCY_SHED_REASONS],
      [...SUPPLY_SHED_REASONS],
      [...TRACKED_SUPPLY_REASONS],
    ]);

    expect(result.rows.map((row) => row.model)).toEqual(["model-a", "model-b"]);

    const model = result.rows[0];
    expect(model).toMatchObject({
      model: "model-a",
      display_name: "Model A",
      min_ram_gb: 64,
      supply_rejects_1h: "2",
      supply_rejects_24h: "3",
      capacity_sheds_1h: "1",
      capacity_sheds_24h: "2",
      latency_sheds_1h: "1",
      unavailable_sheds_1h: "0",
      hardware_mismatches_1h: "1",
      served_24h: "3",
    });
    expect(model.actual_ttft_p95_ms_1h).toBeCloseTo(290);
    expect(model.actual_ttft_p95_ms_24h).toBeCloseTo(480);
    expect(model.rejected_ttft_p95_ms_1h).toBe(4000);
  });
});
