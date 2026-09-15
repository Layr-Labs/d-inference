import { afterAll, beforeAll, describe, expect, it, vi } from "vitest";
import { Pool } from "pg";

const testURL = process.env.APP_ATTEST_TEST_DATABASE_URL;
// This integration test writes fixtures only in the designated disposable DB.
const enabled = !!testURL?.startsWith("postgres://gaj@127.0.0.1:55495/darkbloom_attest_094_test?");
// Keep fixtures on one connection and roll them back, including truncation.
const pool = new Pool({ connectionString: testURL, max: 1 });
vi.mock("@/lib/db", () => ({ query: async (text: string, params: unknown[]) => (await pool.query(text, params)).rows }));

describe.skipIf(!enabled)("App Attest inventory queries on PostgreSQL", () => {
  beforeAll(async () => {
    await pool.query("BEGIN");
    await pool.query("TRUNCATE darkbloom_machines,app_attest_shadow_keys,app_attest_evidence,app_attest_receipts,app_attest_shadow_events,darkbloom_machine_observations CASCADE");
    await pool.query(`INSERT INTO darkbloom_machines VALUES
      ('machine-a','hardware_verified',NULL,NOW()-INTERVAL '2 days',NOW()),
      ('machine-b','provisional',NULL,NOW(),NOW())`);
    const observations = [
      {id:"session-a",machine:"machine-a",hours:2,os:27,protocol:2,enabled:true},
      {id:"session-b",machine:"machine-a",hours:0,os:26,protocol:2,enabled:true},
      {id:"session-c",machine:"machine-b",hours:0,os:0,protocol:0,enabled:false},
    ];
    for (const o of observations) {
      const body=JSON.stringify({source:"live_registration",os_major:o.os,os_version:o.os ? `${o.os}.0` : "",protocol:o.protocol,shadow_enabled:o.enabled,version:"0.9.2",chip:"test"});
      await pool.query(`INSERT INTO darkbloom_machine_sessions VALUES($1,$2,$2,'owner',NOW()-$3::int*INTERVAL '1 hour',NOW()-$3::int*INTERVAL '1 hour',NULL,$4)`,[o.id,o.machine,o.hours,body]);
      await pool.query(`INSERT INTO darkbloom_machine_observations VALUES($1,NOW()-$2::int*INTERVAL '1 hour',$3)`,[o.id,o.hours,body]);
    }
    await pool.query(`INSERT INTO app_attest_shadow_events VALUES('event','session-b',NOW(),'assertion','verified','{"duration_ms":20}')`);
    await pool.query(`INSERT INTO app_attest_evidence(id,session_id,key_id,received_at,action,sha256,context,outcome) VALUES('proof','session-b','key',NOW(),'assertion','sum','{}','verified')`);
  });
  afterAll(async()=>{ await pool.query("ROLLBACK"); await pool.end(); });

  it("counts identities instead of sessions and keeps unknown/disabled cohorts", async()=>{
    const {appAttestCensus,appAttestMachines,appAttestStages,appAttestArchiveHealth,appAttestMachineHistory}=await import("./app-attest");
    const census=await appAttestCensus(7);
    expect(census.machines).toBe("2"); expect(census.sessions).toBe("3"); expect(census.accounts).toBe("1");
    expect(census.macos27).toBe("0"); expect(census.os_unknown).toBe("1"); expect(census.shadow_off).toBe("1");
    expect(census.ever_macos27).toBe("1"); expect(census.verified_machines).toBe("1"); expect(census.credentials).toBe("1");
    const machines=await appAttestMachines(7);
    const known=machines.find(m=>m.machine_id==="machine-a");
    expect(known?.first_macos27).toBeTruthy(); expect(known?.os_version).toBe("26.0"); expect(known?.last_assertion).toBeTruthy();
    expect((await appAttestStages(7))[0].machines).toBe("1");
    expect(await appAttestArchiveHealth(7)).toContainEqual({kind:"proof",outcome:"verified",count:"1"});
    expect((await appAttestMachineHistory("machine-a",0))[0].id).toBe("proof");
    expect(await appAttestMachineHistory("machine-b",0)).toEqual([]);
  });
  it("requires a fresh verdict on the current connection and honors revocation", async()=>{
    const { appAttestReadinessCohorts, appAttestReadinessReasons } = await import("./app-attest-readiness");
    const fields = JSON.stringify({ policy_version:"mac-app-attest-v2", credential_id:"readiness-key", valid_until:new Date(Date.now()+600_000).toISOString(), reasons:[] });
    await pool.query(`INSERT INTO app_attest_shadow_events VALUES('policy','session-b',NOW(),'prospective_policy','eligible',$1)`, [fields]);
    expect(await appAttestReadinessCohorts(7)).toContainEqual({readiness:"eligible",version:"0.9.2",machines:"1"});
    await pool.query(`UPDATE app_attest_shadow_events SET fields=fields || '{"policy_version":"mac-app-attest-v1"}'::jsonb WHERE id='policy'`);
    expect(await appAttestReadinessCohorts(7)).toContainEqual({readiness:"stale",version:"0.9.2",machines:"1"});
    expect(await appAttestReadinessReasons(7)).toEqual([{reason:"policy_version_stale",machines:"1"}]);
    await pool.query(`UPDATE app_attest_shadow_events SET fields=$1::jsonb - 'valid_until' WHERE id='policy'`,[fields]);
    expect(await appAttestReadinessCohorts(7)).toContainEqual({readiness:"stale",version:"0.9.2",machines:"1"});
    expect(await appAttestReadinessReasons(7)).toEqual([{reason:"verdict_expired_or_missing",machines:"1"}]);
    await pool.query(`UPDATE app_attest_shadow_events SET fields=$1 WHERE id='policy'`,[fields]);
    await pool.query(`UPDATE app_attest_shadow_events SET fields=fields || jsonb_build_object('valid_until',NOW()-INTERVAL '1 second') WHERE id='policy'`);
    expect(await appAttestReadinessCohorts(7)).toContainEqual({readiness:"stale",version:"0.9.2",machines:"1"});
    expect(await appAttestReadinessReasons(7)).toEqual([{reason:"verdict_expired_or_missing",machines:"1"}]);
    await pool.query(`UPDATE app_attest_shadow_events SET fields=$1 WHERE id='policy'`,[fields]);
    await pool.query(`INSERT INTO app_attest_shadow_keys(key_id,owner,evidence) VALUES('readiness-key','owner','{}')`);
    await pool.query(`INSERT INTO app_attest_key_revocations VALUES('readiness-key','owner','test',NOW())`);
    expect(await appAttestReadinessCohorts(7)).toContainEqual({readiness:"ineligible",version:"0.9.2",machines:"1"});
    expect(await appAttestReadinessReasons(7)).toEqual([{reason:"credential_revoked",machines:"1"}]);
    await pool.query(`UPDATE app_attest_shadow_events SET fields=fields || '{"reasons":["credential_revoked"]}'::jsonb WHERE id='policy'`);
    expect(await appAttestReadinessReasons(7)).toEqual([{reason:"credential_revoked",machines:"1"}]);
    await pool.query(`INSERT INTO darkbloom_machine_sessions SELECT 'replacement',machine_id,original_machine_id,account_id,NOW(),NOW()+INTERVAL '1 second',NULL,observation FROM darkbloom_machine_sessions WHERE session_id='session-b'`);
    await pool.query(`UPDATE darkbloom_machine_sessions SET disconnected_at=NOW(),last_seen=NOW()+INTERVAL '2 seconds' WHERE session_id='session-b'`);
    expect(await appAttestReadinessCohorts(7)).toEqual([{readiness:"not_evaluated",version:"0.9.2",machines:"2"}]);
    await pool.query(`INSERT INTO app_attest_shadow_events VALUES('missing','replacement',NOW(),'prospective_policy','unknown','{"reasons":["apple_bundle_version_missing"]}')`);
    expect(await appAttestReadinessReasons(7)).toEqual([{reason:"apple_bundle_version_missing",machines:"1"}]);
  });

});
