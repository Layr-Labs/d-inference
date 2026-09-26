import { afterAll, beforeAll, describe, expect, it, vi } from "vitest";
import { Pool } from "pg";
import { pivotDeaths } from "../app-attest-diagnostics";
import {
  appAttestDiagnosticBreakdown, appAttestDiagnosticCohorts, appAttestDiagnosticCoverage,
  appAttestKeyDeathsByDay, appAttestPushReceipt, appAttestRecentKeyDeaths,
  appAttestRotationEvents, appAttestRotationOutcomes,
} from "./app-attest-diagnostics";

const testURL = process.env.APP_ATTEST_TEST_DATABASE_URL;
// This integration test writes fixtures only in the designated disposable DB.
const enabled = !!testURL?.startsWith("postgres://gaj@127.0.0.1:55495/darkbloom_attest_094_test?");
// Keep fixtures on one connection and roll them back, including truncation.
const pool = new Pool({ connectionString: testURL, max: 1 });
// The mock captures `pool` but only reads it when a query runs, after module initialization.
vi.mock("@/lib/db", () => ({ query: async (text: string, params: unknown[]) => (await pool.query(text, params)).rows }));

const session = (id: string, machine: string, os: number, build: string, chip = "Apple M3 Max") =>
  pool.query(`INSERT INTO darkbloom_machine_sessions VALUES($1,$2,$2,'owner',NOW()-INTERVAL '3 days',NOW(),NULL,$3)`,
    [id, machine, JSON.stringify({ os_major: os, os_version: `${os}.0`, os_build: build, version: "0.9.9", chip })]);
const event = (id: string, sessionID: string, stage: string, outcome: string, fields: object, hoursAgo = 1) =>
  pool.query(`INSERT INTO app_attest_shadow_events VALUES($1,$2,NOW()-$5::int*INTERVAL '1 hour',$3,$4,$6)`,
    [id, sessionID, stage, outcome, hoursAgo, JSON.stringify(fields)]);
const evidence = (id: string, sessionID: string, key: string, hoursAgo: number, outcome: string, context: object) =>
  pool.query(`INSERT INTO app_attest_evidence(id,session_id,key_id,received_at,action,sha256,context,outcome)
    VALUES($1,$2,$3,NOW()-$4::int*INTERVAL '1 hour','assertion','sum',$5,$6)`, [id, sessionID, key, hoursAgo, JSON.stringify(context), outcome]);

describe.skipIf(!enabled)("App Attest failure diagnostics on PostgreSQL", () => {
  beforeAll(async () => {
    await pool.query("BEGIN");
    await pool.query("TRUNCATE darkbloom_machines,app_attest_shadow_keys,app_attest_evidence,app_attest_shadow_events,app_attest_key_rotations CASCADE");
    await pool.query(`INSERT INTO darkbloom_machines VALUES
      ('m-new','hardware_verified',NULL,NOW(),NOW()),('m-old','hardware_verified',NULL,NOW(),NOW()),
      ('m-26','hardware_verified',NULL,NOW(),NOW()),('m-rep','hardware_verified',NULL,NOW(),NOW())`);
    await session("s-new", "m-new", 27, "27A100");
    await session("s-old", "m-old", 27, "27A200", "Apple M1");
    await session("s-26", "m-26", 26, "25A1");
    await session("s-rep", "m-rep", 27, "27A100");
    // New client: full diagnostics on an is_supported_false ready reply.
    await event("e1", "s-new", "ready", "unsupported", { availability_reason: "is_supported_false", launch_session: "background",
      console_user_active: false, sip_enabled: true, previous_exit: "clean", start_reason: "launchd",
      preflight: { opt_in_entitlement: true, bundle_path_class: "user_install" }, key_history: { generations_last_24h: 7 } });
    // Old client: same cohort, no diagnostics at all.
    await event("e2", "s-old", "ready", "unsupported", { availability_reason: "is_supported_false", reported_chip: "Apple M1" });
    // macOS 26 events are out of scope.
    await event("e3", "s-26", "ready", "unsupported", { availability_reason: "is_supported_false" });
    await event("e4", "s-new", "attestation", "apple_invalid_key", { native_error_chain: [{ domain: "devicecheck", code: 3 }] });
    await event("e5", "s-new", "assertion", "apple_error", { apple_error: { domain: "devicecheck", code: 0 },
      native_error_chain: [{ domain: "devicecheck", code: 0 }, { domain: "cryptotokenkit", code: -3 }, { domain: "aks", code: -536362989 }],
      rebooted_since_last_success: false, process_restarted_since_last_success: true });
    await event("e6", "s-new", "assertion", "apple_error", { apple_error_source: "proof_oversize" });
    await event("e7", "s-old", "ready", "busy", { operation_stalled_seconds: 900 });
    await event("e8", "s-old", "rollout", "identity_required", {});
    await event("e9", "s-new", "ready", "unsupported", { availability_reason: "is_supported_false" }, 24 * 3);
    await event("r1", "s-new", "rotation", "requested", {});
    await event("r2", "s-old", "rotation", "rate_limited", {});
    // Key deaths: restart (derived flags), OS change (build moved), unknown.
    await evidence("v1", "s-new", "k-restart", 10, "verified", { boot_time: 1_800_000_000, process_started_at: 1_800_000_100 });
    await evidence("d1", "s-new", "k-restart", 2, "apple_error", { apple_error: { domain: "devicecheck", code: 0 },
      process_restarted_since_last_success: true, rebooted_since_last_success: false, previous_exit: "unclean",
      native_error_chain: [{ domain: "devicecheck", code: 0 }, { domain: "aks", code: -536362989 }] });
    await evidence("d1b", "s-new", "k-restart", 1, "apple_error", {});
    await evidence("v2", "s-old", "k-os", 10, "verified", { status: { os_build: "27A150" } });
    await evidence("d2", "s-old", "k-os", 2, "apple_error", { status: { os_build: "27A200" } });
    await evidence("d3", "s-old", "k-unknown", 2, "apple_error", { apple_error: { domain: "devicecheck", code: 0 } });
    await evidence("d4", "s-old", "k-alive", 2, "apple_error", { apple_error_source: "proof_oversize" });
    await evidence("d5", "s-old", "k-other", 2, "apple_error", { apple_error: { domain: "devicecheck", code: 3 } });
    await evidence("d6", "s-26", "k-26", 2, "apple_error", {});
    // Rotation: one replaced and verified, one never replaced.
    await pool.query(`INSERT INTO app_attest_key_rotations VALUES
      ('k-restart','m-rep','owner',NOW()-INTERVAL '5 hours',2,'assertion_apple_error'),
      ('k-os','m-old','owner',NOW()-INTERVAL '5 hours',2,'assertion_apple_error'),
      ('k-ancient','m-old','owner',NOW()-INTERVAL '30 days',2,'assertion_apple_error')`);
    await pool.query(`INSERT INTO app_attest_evidence(id,session_id,key_id,received_at,action,sha256,context,outcome) VALUES
      ('rep-a','s-rep','k-new',NOW()-INTERVAL '4 hours','attestation','sum','{}','verified'),
      ('rep-b','s-rep','k-new',NOW()-INTERVAL '4 hours'+INTERVAL '30 seconds','assertion','sum','{}','verified')`);
  });
  afterAll(async () => { await pool.query("ROLLBACK"); await pool.end(); });

  it("counts every unknown cohort on macOS 27+ only, within the window", async () => {
    expect(await appAttestDiagnosticCohorts(1)).toEqual([
      { cohort: "dead_key_assertion", events: "1", machines: "1" },
      { cohort: "fresh_key_invalid_key", events: "1", machines: "1" },
      { cohort: "identity_required", events: "1", machines: "1" },
      { cohort: "is_supported_false", events: "2", machines: "2" },
      { cohort: "stalled_busy", events: "1", machines: "1" },
    ]);
    expect((await appAttestDiagnosticCohorts(7)).find(c => c.cohort === "is_supported_false")?.events).toBe("3");
    expect(await appAttestDiagnosticCoverage(1)).toEqual({ machines: "3", ready_events: "3", diagnosed_events: "1", diagnosed_machines: "1" });
  });

  it("excludes generic busy and malformed stall durations", async () => {
    await pool.query("SAVEPOINT busy");
    try {
      const invalid = [undefined, null, "900", -1, 0, 1.5, 86401, true, {}];
      for (const [i, value] of invalid.entries()) {
        await event(`busy-${i}`, "s-new", "ready", "busy", { operation_stalled_seconds: value });
      }
      expect((await appAttestDiagnosticCohorts(1)).find(c => c.cohort === "stalled_busy"))
        .toEqual({ cohort: "stalled_busy", events: "1", machines: "1" });
      expect((await appAttestDiagnosticBreakdown(1)).filter(r => r.cohort === "stalled_busy" && r.dimension === "operation_stalled_seconds"))
        .toMatchObject([{ value: "10-60m", events: "1" }]);
    } finally {
      await pool.query("ROLLBACK TO SAVEPOINT busy");
    }
  });

  it("breaks cohorts down by diagnostics and reports old rows as missing", async () => {
    const rows = await appAttestDiagnosticBreakdown(1);
    const pick = (cohort: string, dimension: string) => rows.filter(r => r.cohort === cohort && r.dimension === dimension)
      .map(r => [r.value, r.events]);
    expect(pick("is_supported_false", "console_user_active")).toEqual([["false", "1"], [null, "1"]]);
    expect(pick("is_supported_false", "preflight.bundle_path_class")).toEqual([["user_install", "1"], [null, "1"]]);
    expect(pick("is_supported_false", "preflight.environment_entitlement")).toEqual([[null, "2"]]);
    expect(pick("is_supported_false", "key_history.generations_last_24h")).toEqual([["6-20", "1"], [null, "1"]]);
    expect(pick("is_supported_false", "chip_family")).toEqual([["M1", "1"], ["M3", "1"]]);
    expect(pick("is_supported_false", "os_build")).toEqual([["27A100", "1"], ["27A200", "1"]]);
    expect(pick("dead_key_assertion", "native_error_chain")).toEqual([["devicecheck:0 → cryptotokenkit:-3 → aks:-536362989", "1"]]);
    expect(pick("dead_key_assertion", "native_error_entry")).toEqual([["aks:-536362989", "1"], ["cryptotokenkit:-3", "1"], ["devicecheck:0", "1"]]);
    expect(pick("dead_key_assertion", "process_restarted_since_last_success")).toEqual([["true", "1"]]);
    expect(pick("stalled_busy", "operation_stalled_seconds")).toEqual([["10-60m", "1"]]);
    expect(pick("identity_required", "native_error_entry")).toEqual([[null, "1"]]);
  });

  it("classifies each dead key once by OS change, reboot or process restart", async () => {
    const byClass = Object.fromEntries((await appAttestKeyDeathsByDay(1)).map(r => [r.classification, [r.keys, r.clean_exit, r.unclean_exit]]));
    expect(byClass).toEqual({ os_change: ["1", "0", "0"], process_restart: ["1", "0", "1"], unknown: ["1", "0", "0"] });
    // m-old has dead keys in two classes: the day counts it once.
    const byDay = await appAttestKeyDeathsByDay(1);
    expect(byDay.reduce((sum, r) => sum + Number(r.machines), 0)).toBe(3);
    expect(new Set(byDay.map(r => r.day_machines))).toEqual(new Set(["2"]));
    expect(pivotDeaths(byDay)[0].machines).toBe(2);
    const recent = await appAttestRecentKeyDeaths(1);
    const restart = recent.find(r => r.key_id === "k-restart");
    expect(restart).toMatchObject({ classification: "process_restart", previous_exit: "unclean", native_error_chain: "devicecheck:0 → aks:-536362989" });
    expect(restart?.last_success_at).toBeTruthy();
    expect(recent.find(r => r.key_id === "k-os")).toMatchObject({ os_build_before: "27A150", os_build_after: "27A200" });
    expect(recent.map(r => r.key_id).sort()).toEqual(["k-os", "k-restart", "k-unknown"]);
  });

  it("falls back to boot_time on rows without derived flags", async () => {
    await pool.query("SAVEPOINT fallback");
    try {
      await evidence("v9", "s-new", "k-boot", 10, "verified", { boot_time: 1_800_000_000 });
      await evidence("d9", "s-new", "k-boot", 2, "apple_error", { boot_time: 1_800_050_000 });
      expect((await appAttestRecentKeyDeaths(1)).find(r => r.key_id === "k-boot")?.classification).toBe("reboot");
    } finally {
      await pool.query("ROLLBACK TO SAVEPOINT fallback");
    }
  });

  it("reports rotation requests, replacement outcomes and decisions", async () => {
    const [row] = await appAttestRotationOutcomes(1);
    expect(row).toMatchObject({ reason: "assertion_apple_error", requested: "2", scopes: "2", replacement_attested: "1", replacement_verified: "1" });
    expect(row.median_seconds_to_verified).toBeCloseTo(3630, 0);
    expect(await appAttestRotationEvents(1)).toEqual([
      { stage: "rotation", outcome: "rate_limited", events: "1", machines: "1" },
      { stage: "rotation", outcome: "requested", events: "1", machines: "1" },
    ]);
  });

  it("finds replacement proofs after chained machine merges and preserves account scopes", async () => {
    await pool.query("SAVEPOINT merged_rotation");
    try {
      await pool.query(`INSERT INTO darkbloom_machines VALUES
        ('m-middle','hardware_verified',NULL,NOW(),NOW()),
        ('m-survivor','hardware_verified',NULL,NOW(),NOW())`);
      await pool.query("UPDATE darkbloom_machines SET merged_into='m-middle' WHERE id='m-rep'");
      await pool.query("UPDATE darkbloom_machines SET merged_into='m-survivor' WHERE id='m-middle'");
      await pool.query("UPDATE darkbloom_machine_sessions SET machine_id='m-survivor' WHERE machine_id='m-rep'");
      const [merged] = await appAttestRotationOutcomes(1);
      expect(merged).toMatchObject({ requested: "2", scopes: "2", replacement_attested: "1", replacement_verified: "1" });
      expect(merged.median_seconds_to_verified).toBeCloseTo(3630, 0);
      // A later request under the survivor is the same machine scope. The
      // account fallback remains separate and can still find its proofs.
      await pool.query(`INSERT INTO app_attest_key_rotations VALUES
        ('k-survivor','m-survivor','owner',NOW()-INTERVAL '5 hours',2,'assertion_apple_error'),
        ('k-account','account:owner','owner',NOW()-INTERVAL '5 hours',2,'assertion_apple_error')`);
      expect((await appAttestRotationOutcomes(1))[0]).toMatchObject({
        requested: "4", scopes: "3", replacement_attested: "3", replacement_verified: "3",
      });
    } finally {
      await pool.query("ROLLBACK TO SAVEPOINT merged_rotation");
    }
  });

  it("summarizes APNs push receipt from the latest ready per machine on every OS", async () => {
    await pool.query("SAVEPOINT pushes");
    try {
      // An older ready with push_history is superseded by the latest ready.
      await event("p0", "s-26", "ready", "unsupported", { push_history: { device_token_present: false } }, 2);
      await event("p1", "s-26", "ready", "unsupported", { push_history: { device_token_present: true, pushes_received_last_24h: 5,
        last_push_received_age_seconds: 7200, last_reply_sent_age_seconds: 10_000 } }, 0);
      await event("p2", "s-new", "ready", "unsupported", { push_history: { device_token_present: false, pushes_received_last_24h: 0 } }, 0);
      // Wrongly typed members count as no data; a reply after the push answers it.
      await event("p3", "s-rep", "ready", "unsupported", { push_history: { device_token_present: "yes", pushes_received_last_24h: "12",
        last_push_received_age_seconds: 30, last_reply_sent_age_seconds: 10 } }, 0);
      // s-old's latest ready predates push_history (old client).
      expect(await appAttestPushReceipt(1)).toEqual([
        { os_group: "<27", machines: "1", token_true: "1", token_false: "0", token_no_data: "0",
          pushes_0: "0", pushes_1_3: "0", pushes_4_10: "1", pushes_over_10: "0", pushes_no_data: "0",
          age_under_1h: "0", age_1_24h: "1", age_over_24h: "0", age_never_or_no_data: "0", last_push_unanswered: "1" },
        { os_group: ">=27", machines: "3", token_true: "0", token_false: "1", token_no_data: "2",
          pushes_0: "1", pushes_1_3: "0", pushes_4_10: "0", pushes_over_10: "0", pushes_no_data: "2",
          age_under_1h: "1", age_1_24h: "0", age_over_24h: "0", age_never_or_no_data: "2", last_push_unanswered: "0" },
      ]);
    } finally {
      await pool.query("ROLLBACK TO SAVEPOINT pushes");
    }
  });
});
