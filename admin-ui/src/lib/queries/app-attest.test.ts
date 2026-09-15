import { afterAll, beforeAll, describe, expect, it, vi } from "vitest";
import { Pool } from "pg";

const testURL = process.env.APP_ATTEST_TEST_DATABASE_URL;
// This integration test writes fixtures only in the designated disposable DB.
const enabled = !!testURL?.startsWith("postgres://gaj@127.0.0.1:55495/");
const pool = new Pool({ connectionString: testURL });
vi.mock("@/lib/db", () => ({ query: async (text: string, params: unknown[]) => (await pool.query(text, params)).rows }));

describe.skipIf(!enabled)("App Attest inventory queries on PostgreSQL", () => {
  beforeAll(async () => {
    await pool.query("TRUNCATE darkbloom_machines,app_attest_evidence,app_attest_receipts,app_attest_shadow_events,darkbloom_machine_observations CASCADE");
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
  afterAll(async()=>{ await pool.end(); });

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
});
