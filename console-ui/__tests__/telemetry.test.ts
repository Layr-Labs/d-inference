import { describe, expect, expectTypeOf, it } from "vitest";
import { NextRequest } from "next/server";
import telemetryFixtureJSON from "../../fixtures/telemetry/v1/events.json";
import type {
  TelemetryEvent,
  TelemetryKind,
  TelemetrySeverity,
  TelemetrySource,
} from "@/lib/telemetry-types";
import { stubUpstreamFetch } from "./helpers/route-harness";

type RequiredKeys<T> = {
  [K in keyof T]-?: object extends Pick<T, K> ? never : K;
}[keyof T];
type OptionalKeys<T> = Exclude<keyof T, RequiredKeys<T>>;

function assertTelemetryFixtureSchema(value: unknown): void {
  if (typeof value !== "object" || value === null) {
    throw new Error("invalid telemetry fixture");
  }
  if (!("schema_version" in value)) {
    throw new Error("telemetry fixture schema version is missing");
  }
  const schemaVersion = value.schema_version;
  if (schemaVersion !== 1) {
    throw new Error(`unsupported telemetry fixture schema version ${String(schemaVersion)}`);
  }
}

describe("telemetry wire fixture", () => {
  it("pins the TypeScript vocabulary and event field types", () => {
    expectTypeOf<TelemetrySource>().toEqualTypeOf<
      keyof typeof telemetryFixtureJSON.vocabularies.sources
    >();
    expectTypeOf<TelemetrySeverity>().toEqualTypeOf<
      keyof typeof telemetryFixtureJSON.vocabularies.severities
    >();
    expectTypeOf<TelemetryKind>().toEqualTypeOf<
      keyof typeof telemetryFixtureJSON.vocabularies.kinds
    >();

    type FixtureRequiredFields = keyof typeof telemetryFixtureJSON.required_event_fields;
    type FixtureOptionalFields = keyof typeof telemetryFixtureJSON.optional_event_fields;
    expectTypeOf<keyof TelemetryEvent>().toEqualTypeOf<
      FixtureRequiredFields | FixtureOptionalFields
    >();
    expectTypeOf<RequiredKeys<TelemetryEvent>>().toEqualTypeOf<FixtureRequiredFields>();
    expectTypeOf<OptionalKeys<TelemetryEvent>>().toEqualTypeOf<FixtureOptionalFields>();
  });

  it("consumes named JSON cases for casing and optional omission", () => {
    assertTelemetryFixtureSchema(telemetryFixtureJSON);
    const fixture = telemetryFixtureJSON;
    const requiredFields = Object.keys(fixture.required_event_fields);
    const optionalFields = Object.keys(fixture.optional_event_fields);
    const declaredFields = new Set([...requiredFields, ...optionalFields]);

    expect(Object.values(fixture.required_event_fields).every(Boolean)).toBe(true);
    expect(Object.values(fixture.optional_event_fields).every(Boolean)).toBe(true);
    expect(Object.values(fixture.vocabularies.sources).every(Boolean)).toBe(true);
    expect(Object.values(fixture.vocabularies.severities).every(Boolean)).toBe(true);
    expect(Object.values(fixture.vocabularies.kinds).every(Boolean)).toBe(true);
    expect(fixture.cases.length).toBeGreaterThan(0);

    const names = new Set<string>();
    let sawOmissionCase = false;
    let sawAllFieldsCase = false;
    for (const fixtureCase of fixture.cases) {
      expect(fixtureCase.name).not.toBe("");
      expect(names.has(fixtureCase.name)).toBe(false);
      names.add(fixtureCase.name);

      const event = fixtureCase.event;
      for (const field of requiredFields) {
        expect(event).toHaveProperty(field);
      }
      for (const field of Object.keys(event)) {
        expect(declaredFields.has(field)).toBe(true);
      }

      const omittedFields = new Set<string>();
      for (const field of fixtureCase.omitted_keys) {
        expect(optionalFields).toContain(field);
        expect(omittedFields.has(field)).toBe(false);
        omittedFields.add(field);
        expect(event).not.toHaveProperty(field);
      }
      for (const field of optionalFields) {
        expect(!(field in event)).toBe(omittedFields.has(field));
      }

      expect(fixture.vocabularies.sources).toHaveProperty(String(event.source), true);
      expect(fixture.vocabularies.severities).toHaveProperty(String(event.severity), true);
      expect(fixture.vocabularies.kinds).toHaveProperty(String(event.kind), true);

      sawOmissionCase ||= omittedFields.size > 0;
      sawAllFieldsCase ||= [...declaredFields].every((field) => field in event);
    }
    expect(sawOmissionCase).toBe(true);
    expect(sawAllFieldsCase).toBe(true);
  });

  it("fails closed on a missing or unsupported schema version", () => {
    expect(() => assertTelemetryFixtureSchema({ cases: [] })).toThrow(/missing/);
    expect(() => assertTelemetryFixtureSchema({ schema_version: 2, cases: [] })).toThrow(
      /unsupported/,
    );
  });
});

// Privacy regressions for the retired browser telemetry client and proxy.
const upstream = stubUpstreamFetch();

describe("/api/telemetry route", () => {
  it("returns 410 without inspecting or forwarding the request", async () => {
    const { POST } = await import("@/app/api/telemetry/route");
    const poisonedRequest = new Proxy({} as NextRequest, {
      get() {
        throw new Error("disabled telemetry route inspected request data");
      },
    });

    const response = await POST(poisonedRequest);

    expect(response.status).toBe(410);
    expect(upstream.fetch).not.toHaveBeenCalled();
    await expect(response.json()).resolves.toMatchObject({
      error: { code: "telemetry_ingest_disabled" },
    });
  });

  it("does not reflect an arbitrary request body", async () => {
    const { POST } = await import("@/app/api/telemetry/route");
    const request = new NextRequest("http://localhost:3000/api/telemetry", {
      method: "POST",
      body: "PROMPT_LEAK_SENTINEL",
    });

    const response = await POST(request);
    const body = await response.text();

    expect(response.status).toBe(410);
    expect(body).not.toContain("PROMPT_LEAK_SENTINEL");
    expect(upstream.fetch).not.toHaveBeenCalled();
  });
});

describe("telemetry client", () => {
  it("drops free-form events without buffering or sending", async () => {
    const telemetry = await import("@/lib/telemetry");
    telemetry._resetForTest();

    telemetry.emit({
      kind: "http_error",
      severity: "error",
      message: "PROMPT_LEAK_SENTINEL",
      fields: {
        prompt: "SECRET",
        url: "https://attacker.invalid/private",
      },
      stack: "STACK_LEAK_SENTINEL",
      requestId: "REQUEST_LEAK_SENTINEL",
    });

    expect(telemetry._bufferSize()).toBe(0);
    expect(upstream.fetch).not.toHaveBeenCalled();
  });
});
