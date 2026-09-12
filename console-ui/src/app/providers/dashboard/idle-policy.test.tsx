// @vitest-environment jsdom
import { describe, it, expect } from "vitest";
import { render, screen } from "@testing-library/react";
import { ModelsStrip } from "./ModelsStrip";
import { describeIdlePolicy, formatIdleWindow } from "./format";
import { computeWarnings } from "../warnings";
import { resolveFix } from "./fixes";
import { makeProvider } from "./testFixtures";

const ctx = {
  latest_provider_version: "0.6.5",
  min_provider_version: "0.6.0",
  heartbeat_timeout_seconds: 90,
  challenge_max_age_seconds: 360,
};

const catalog = [{ id: "mlx-community/model-a" }, { id: "mlx-community/model-b" }];
const POLICY = "idle-policy";
const SLEEPING = "models-sleeping";

describe("idle-memory policy wording", () => {
  it("formats the idle window like the CLI does", () => {
    expect(formatIdleWindow(45)).toBe("45 min");
    expect(formatIdleWindow(60)).toBe("1 h");
    expect(formatIdleWindow(90)).toBe("1 h 30 min");
    expect(formatIdleWindow(120)).toBe("2 h");
  });

  it("says nothing when the machine has not reported a policy", () => {
    expect(describeIdlePolicy(undefined)).toBeUndefined();
    expect(describeIdlePolicy(-1)).toBeUndefined();
  });

  it("distinguishes always-ready (0) from free-when-idle (N)", () => {
    expect(describeIdlePolicy(0)).toBe("Always ready — models stay loaded");
    expect(describeIdlePolicy(60)).toMatch(/Free when idle — unloads after 1 h without requests/);
    expect(describeIdlePolicy(60)).toMatch(/reloads on demand/);
  });
});

describe("ModelsStrip idle-memory policy line", () => {
  it("shows the policy for an online machine", () => {
    render(
      <ModelsStrip
        provider={makeProvider({ status: "serving", online: true, models: catalog, warm_models: [catalog[0].id], idle_unload_mins: 0 })}
      />,
    );
    expect(screen.getByTestId(POLICY)).toHaveTextContent(/Always ready/);
    expect(screen.queryByTestId(SLEEPING)).toBeNull();
  });

  it("hides the policy for an offline machine or an unreported policy", () => {
    const { unmount } = render(
      <ModelsStrip provider={makeProvider({ status: "offline", online: false, models: catalog, idle_unload_mins: 60 })} />,
    );
    expect(screen.queryByTestId(POLICY)).toBeNull();
    unmount();

    render(<ModelsStrip provider={makeProvider({ status: "online", online: true, models: catalog, warm_models: [catalog[0].id] })} />);
    expect(screen.queryByTestId(POLICY)).toBeNull();
  });

  it("explains an empty Loaded set as sleeping under free-when-idle only", () => {
    const { unmount } = render(
      <ModelsStrip provider={makeProvider({ status: "online", online: true, models: catalog, warm_models: [], idle_unload_mins: 60 })} />,
    );
    expect(screen.getByTestId(SLEEPING)).toHaveTextContent(/sleeping until the next request/);
    expect(screen.getByTestId(POLICY)).toHaveTextContent(/unloads after 1 h without requests/);
    unmount();

    // Always ready with nothing loaded is NOT sleeping — that is a real gap.
    render(<ModelsStrip provider={makeProvider({ status: "online", online: true, models: catalog, warm_models: [], idle_unload_mins: 0 })} />);
    expect(screen.queryByTestId(SLEEPING)).toBeNull();
  });
});

describe("cold-slot warning under the idle policy", () => {
  const coldSlots = {
    backend_capacity: {
      slots: [{ model: "mlx-community/model-a", state: "idle_shutdown" }],
    } as never,
  };

  it("quotes the machine's own idle window when it is known", () => {
    const p = makeProvider({ status: "online", online: true, idle_unload_mins: 90, ...coldSlots });
    const w = computeWarnings(p, ctx).find((x) => x.id === "backend_idle_shutdown");
    expect(w).toBeTruthy();
    expect(w!.title).toMatch(/reloads on demand/);
    expect(w!.detail).toMatch(/unloaded after 1 h 30 min without requests/);
    expect(w!.detail).toMatch(/darkbloom idle keep-loaded/);
    expect(w!.detail).not.toMatch(/1h of idle/);
  });

  it("falls back to a generic window for providers that do not report one", () => {
    const p = makeProvider({ status: "online", online: true, ...coldSlots });
    const w = computeWarnings(p, ctx).find((x) => x.id === "backend_idle_shutdown");
    expect(w!.detail).toMatch(/after the idle window/);
  });

  it("offers keep-loaded as the way to opt out", () => {
    const fix = resolveFix("backend_idle_shutdown");
    expect(fix.kind).toBe("guidance");
    expect(fix.note).toMatch(/darkbloom idle keep-loaded/);
  });
});
