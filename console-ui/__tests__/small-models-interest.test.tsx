import { act, cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react";
import { StrictMode } from "react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { SmallModelsInterest } from "@/app/earn/SmallModelsInterest";
import type { EarningsCalculator } from "@/app/earn/useEarningsCalculator";
import { trackEvent } from "@/lib/google-analytics";

vi.mock("@/lib/google-analytics", () => ({ trackEvent: vi.fn() }));

const hardware = { macType: "MacBook Pro", chip: "M1" };
const calc = { hardware, effectiveRAM: 16 } as EarningsCalculator;
const productionCalc = {
  hardware: { macType: "MacBook Pro", chip: "M4 Pro" }, effectiveRAM: 24,
} as EarningsCalculator;
const token = "synthetic-privy-session";
const login = vi.fn();
const getAccessToken = vi.fn<() => Promise<string | null>>(async () => token);
const fetchMock = vi.fn<typeof fetch>();
const buttonName = "Notify me when smaller models launch";
const confirmation = /You're on the list/;

function props(authenticated = false) {
  return { calc, ready: true, authenticated, login,
    accountId: authenticated ? "account-a" : null, getAccessToken };
}

function posts() {
  return fetchMock.mock.calls.filter(([, init]) => init?.method === "POST");
}

beforeEach(() => {
  window.localStorage.clear();
  vi.clearAllMocks();
  getAccessToken.mockResolvedValue(token);
  fetchMock.mockImplementation(async (_url, init) => {
    if (init?.method === "POST") return new Promise<Response>(() => {});
    return new Response(null, { status: 404 });
  });
  vi.stubGlobal("fetch", fetchMock);
});
afterEach(() => { cleanup(); vi.unstubAllGlobals(); vi.restoreAllMocks(); vi.useRealTimers(); });

describe("small model interest durable acknowledgment", () => {
  it("503-F01 signed-out click opens login without confirming registration", () => {
    render(<SmallModelsInterest {...props()} />);
    fireEvent.click(screen.getByRole("button", { name: buttonName }));
    expect(login).toHaveBeenCalledTimes(1);
    expect(screen.queryByText(confirmation)).not.toBeInTheDocument();
    expect(posts()).toHaveLength(0);
  });

  it("503-F02 actual auth rerender submits selected hardware and waits for acknowledgment", async () => {
    const view = render(<SmallModelsInterest {...props()} />);
    fireEvent.click(screen.getByRole("button", { name: buttonName }));
    view.rerender(<SmallModelsInterest {...props(true)} />);
    await waitFor(() => expect(posts()).toHaveLength(1));
    expect(posts()[0][0]).toBe("/api/interest/small-models");
    expect(JSON.parse(posts()[0][1]!.body as string)).toEqual({
      mac_type: hardware.macType, chip: hardware.chip, ram_gb: 16,
    });
    expect(screen.queryByText(confirmation)).not.toBeInTheDocument();
  });

  it("503-F03 authenticated click waits for a successful registration response", () => {
    render(<SmallModelsInterest {...props(true)} />);
    fireEvent.click(screen.getByRole("button", { name: buttonName }));
    expect(screen.queryByText(confirmation)).not.toBeInTheDocument();
  });

  it("503-F07 production-readiness click also waits for durable acknowledgment", () => {
    render(<SmallModelsInterest {...props()} calc={productionCalc} variant="production-readiness" />);
    fireEvent.click(screen.getByRole("button", { name: "Register your interest" }));
    expect(login).toHaveBeenCalledTimes(1);
    expect(screen.queryByText(confirmation)).not.toBeInTheDocument();
  });

  it("control: untouched signed-out component has no registration side effects", () => {
    render(<SmallModelsInterest {...props()} />);
    expect(login).not.toHaveBeenCalled();
    expect(fetchMock).not.toHaveBeenCalled();
    expect(trackEvent).not.toHaveBeenCalled();
  });

  it("control: auth initialization disables registration", () => {
    render(<SmallModelsInterest {...props()} ready={false} />);
    const button = screen.getByRole("button", { name: buttonName });
    expect(button).toBeDisabled();
    fireEvent.click(button);
    expect(login).not.toHaveBeenCalled();
    expect(posts()).toHaveLength(0);
  });

  it("control: an authenticated click does not reopen login", () => {
    render(<SmallModelsInterest {...props(true)} />);
    fireEvent.click(screen.getByRole("button", { name: buttonName }));
    expect(login).not.toHaveBeenCalled();
  });

  it("control: both supported CTA variants initially offer their registration action", () => {
    const view = render(<SmallModelsInterest {...props()} />);
    expect(screen.getByRole("button", { name: buttonName })).toBeEnabled();
    view.rerender(<SmallModelsInterest {...props()} calc={productionCalc} variant="production-readiness" />);
    expect(screen.getByRole("button", { name: "Register your interest" })).toBeEnabled();
    expect(screen.queryByText(confirmation)).not.toBeInTheDocument();
  });
});

function deferred<T>() {
  let resolve!: (value: T) => void;
  const promise = new Promise<T>((done) => { resolve = done; });
  return { promise, resolve };
}
const saved = { mac_type: "MacBook Pro", chip: "M1", ram_gb: 16, created_at: "2026-10-01T00:00:00Z", updated_at: "2026-10-01T00:00:00Z" };
const absent = () => Promise.resolve(new Response(null, { status: 404 }));
const clickRegister = () => fireEvent.click(screen.getByRole("button", { name: buttonName }));

describe("503 authenticated persistence and session controls", () => {
  it("503-F03 sends exactly one authenticated POST and confirms only after204", async () => {
    const post = deferred<Response>();
    fetchMock.mockImplementation((_url, init) => init?.method === "POST" ? post.promise : absent());
    render(<StrictMode><SmallModelsInterest {...props(true)} /></StrictMode>);
    const button = screen.getByRole("button", { name: buttonName });
    fireEvent.click(button); fireEvent.click(button);
    await waitFor(() => expect(posts()).toHaveLength(1));
    expect(posts()[0][1]?.headers).toMatchObject({ Authorization: `Bearer ${token}` });
    expect(JSON.parse(posts()[0][1]!.body as string)).toEqual({ mac_type: "MacBook Pro", chip: "M1", ram_gb: 16 });
    expect(screen.queryByText(confirmation)).not.toBeInTheDocument();
    await act(async () => post.resolve(new Response(null, { status: 204 })));
    expect(screen.getByText(confirmation)).toBeInTheDocument();
    expect(trackEvent).toHaveBeenCalledTimes(1);
  });

  it("503-F01 explicit cancel disarms later unrelated login and permits manual retry", async () => {
    fetchMock.mockImplementation((_url, init) => init?.method === "POST" ? Promise.resolve(new Response(null, { status: 204 })) : absent());
    const view = render(<SmallModelsInterest {...props()} />);
    clickRegister();
    expect(screen.getByRole("status")).toHaveTextContent("still pending");
    fireEvent.click(screen.getByRole("button", { name: "Cancel registration" }));
    view.rerender(<SmallModelsInterest {...props(true)} />);
    await act(async () => {});
    expect(posts()).toHaveLength(0);
    clickRegister();
    expect(await screen.findByText(confirmation)).toBeInTheDocument();
    expect(posts()).toHaveLength(1);
  });

  it.each([401, 429, 500, 422, 200])("503-F04 status%s never confirms and a manual retry can succeed", async (status) => {
    fetchMock.mockImplementation((_url, init) => init?.method === "POST" ? Promise.resolve(new Response("{}", { status })) : absent());
    render(<SmallModelsInterest {...props(true)} />);
    clickRegister();
    expect(await screen.findByRole("alert")).toBeInTheDocument();
    expect(screen.queryByText(confirmation)).not.toBeInTheDocument();
    fetchMock.mockImplementation((_url, init) => init?.method === "POST" ? Promise.resolve(new Response(null, { status: 204 })) : absent());
    clickRegister();
    expect(await screen.findByText(confirmation)).toBeInTheDocument();
    expect(posts()).toHaveLength(2);
  });

  it("503-F04 network failure remains actionable", async () => {
    fetchMock.mockRejectedValue(new TypeError("offline"));
    render(<SmallModelsInterest {...props(true)} />); clickRegister();
    expect(await screen.findByRole("alert")).toBeInTheDocument();
    expect(screen.getByRole("button", { name: buttonName })).toBeEnabled();
    expect(screen.queryByText(confirmation)).not.toBeInTheDocument();
  });

  it("503-F04 missing session token never posts or confirms", async () => {
    getAccessToken.mockResolvedValue(null);
    render(<SmallModelsInterest {...props(true)} />); clickRegister();
    expect(await screen.findByRole("alert")).toHaveTextContent("Sign in again");
    expect(posts()).toHaveLength(0);
    expect(screen.queryByText(confirmation)).not.toBeInTheDocument();
  });

  it("503-F04 bounded timeout releases pending request for retry", async () => {
    vi.useFakeTimers();
    render(<SmallModelsInterest {...props(true)} />); clickRegister();
    await act(async () => { await Promise.resolve(); });
    expect(posts()).toHaveLength(1);
    await act(async () => { await vi.advanceTimersByTimeAsync(10_001); });
    expect(screen.getByRole("alert")).toHaveTextContent("timed out");
    expect(screen.getByRole("button", { name: buttonName })).toBeEnabled();
    expect(screen.queryByText(confirmation)).not.toBeInTheDocument();
  });

  it.each(["account-b", null])("503-F05 late A acknowledgment is ignored after session changes to%s", async (next) => {
    const post = deferred<Response>();
    fetchMock.mockImplementation((_url, init) => init?.method === "POST" ? post.promise : absent());
    const view = render(<SmallModelsInterest {...props(true)} />); clickRegister();
    await waitFor(() => expect(posts()).toHaveLength(1));
    view.rerender(<SmallModelsInterest {...props(!!next)} accountId={next} />);
    await act(async () => post.resolve(new Response(null, { status: 204 })));
    expect(screen.queryByText(confirmation)).not.toBeInTheDocument();
    expect(posts()).toHaveLength(1);
    expect((posts()[0][1]!.signal as AbortSignal).aborted).toBe(true);
  });

  it("503-F05 token resolution after account switch cannot submit A intent", async () => {
    const session = deferred<string | null>();
    const delayed = vi.fn(() => session.promise);
    const view = render(<SmallModelsInterest {...props(true)} getAccessToken={delayed} />); clickRegister();
    view.rerender(<SmallModelsInterest {...props(true)} accountId="account-b" />);
    await act(async () => session.resolve("session-b"));
    expect(posts()).toHaveLength(0);
    expect(screen.queryByText(confirmation)).not.toBeInTheDocument();
  });

  it("503-F06 ignores legacy anonymous success markers", () => {
    localStorage.setItem("darkbloom.smallModelsInterest", JSON.stringify({ at: Date.now() }));
    localStorage.setItem("darkbloom.productionReadinessInterest", "true");
    render(<SmallModelsInterest {...props()} />);
    expect(screen.getByRole("button", { name: buttonName })).toBeEnabled();
    expect(screen.queryByText(confirmation)).not.toBeInTheDocument();
    expect(posts()).toHaveLength(0);
  });

  it("503-F06 remount reads the authenticated server record without automatic registration", async () => {
    fetchMock.mockResolvedValue(Response.json(saved));
    const view = render(<SmallModelsInterest {...props(true)} />);
    expect(await screen.findByText(confirmation)).toBeInTheDocument();
    view.unmount();
    fetchMock.mockResolvedValue(Response.json(saved));
    render(<SmallModelsInterest {...props(true)} />);
    expect(await screen.findByText(confirmation)).toBeInTheDocument();
    expect(posts()).toHaveLength(0);
  });

  it("503-F06 storage denial does not prevent authenticated persistence", async () => {
    vi.spyOn(window.localStorage, "getItem").mockImplementation(() => { throw new Error("denied"); });
    vi.spyOn(window.localStorage, "setItem").mockImplementation(() => { throw new Error("denied"); });
    vi.spyOn(window.localStorage, "removeItem").mockImplementation(() => { throw new Error("denied"); });
    fetchMock.mockImplementation((_url, init) => init?.method === "POST" ? Promise.resolve(new Response(null, { status: 204 })) : absent());
    render(<SmallModelsInterest {...props(true)} />); clickRegister();
    expect(await screen.findByText(confirmation)).toBeInTheDocument();
  });

  it("503-F06 stale readable intent cannot rearm after cancellation when storage writes fail", async () => {
    const stale = JSON.stringify({ hardware: saved, accountId: null, armed: true, at: Date.now() });
    vi.spyOn(window.localStorage, "getItem").mockReturnValue(stale);
    vi.spyOn(window.localStorage, "setItem").mockImplementation(() => { throw new Error("quota"); });
    vi.spyOn(window.localStorage, "removeItem").mockImplementation(() => { throw new Error("denied"); });
    const view = render(<SmallModelsInterest {...props()} />);
    clickRegister(); fireEvent.click(screen.getByRole("button", { name: "Cancel registration" }));
    view.unmount();
    render(<SmallModelsInterest {...props(true)} />);
    await act(async () => {});
    expect(posts()).toHaveLength(0);
    expect(screen.getByRole("button", { name: buttonName })).toBeEnabled();
    expect(screen.queryByText(confirmation)).not.toBeInTheDocument();
  });

  it("503-F06 malformed and expired pending storage cannot enroll on login", async () => {
    localStorage.setItem("darkbloom.smallModelsInterest.pending.v1", "{broken");
    const view = render(<SmallModelsInterest {...props()} />);
    expect(screen.getByRole("button", { name: buttonName })).toBeEnabled();
    view.unmount();
    localStorage.setItem("darkbloom.smallModelsInterest.pending.v1", JSON.stringify({ hardware: saved, accountId: null, armed: true, at: Date.now() - 16 * 60 * 1000 }));
    render(<SmallModelsInterest {...props(true)} />);
    await act(async () => {});
    expect(posts()).toHaveLength(0);
  });

  it("503-F01 pending sign-in intent expires without submitting", async () => {
    vi.useFakeTimers();
    const view = render(<SmallModelsInterest {...props()} />); clickRegister();
    await act(async () => { await vi.advanceTimersByTimeAsync(15 * 60 * 1000 + 1); });
    expect(screen.getByRole("button", { name: buttonName })).toBeEnabled();
    view.rerender(<SmallModelsInterest {...props(true)} />);
    await act(async () => {});
    expect(posts()).toHaveLength(0);
  });

  it("503-F07 production-readiness selection survives auth transition and204", async () => {
    fetchMock.mockImplementation((_url, init) => init?.method === "POST" ? Promise.resolve(new Response(null, { status: 204 })) : absent());
    const view = render(<SmallModelsInterest {...props()} calc={productionCalc} variant="production-readiness" />);
    fireEvent.click(screen.getByRole("button", { name: "Register your interest" }));
    view.rerender(<SmallModelsInterest {...props(true)} calc={productionCalc} variant="production-readiness" />);
    expect(await screen.findByText(confirmation)).toBeInTheDocument();
    expect(JSON.parse(posts()[0][1]!.body as string)).toEqual({ mac_type: "MacBook Pro", chip: "M4 Pro", ram_gb: 24 });
  });

  it("503-F08 changed hardware exposes a new upsert action after acknowledgment", async () => {
    fetchMock.mockImplementation((_url, init) => init?.method === "POST" ? Promise.resolve(new Response(null, { status: 204 })) : absent());
    const view = render(<SmallModelsInterest {...props(true)} />); clickRegister();
    await screen.findByText(confirmation);
    view.rerender(<SmallModelsInterest {...props(true)} calc={productionCalc} />);
    clickRegister();
    await screen.findByText(confirmation);
    expect(posts()).toHaveLength(2);
    expect(JSON.parse(posts()[1][1]!.body as string).ram_gb).toBe(24);
  });

  it("503-F08 stale initial GET cannot overwrite a newer successful upsert", async () => {
    const get = deferred<Response>();
    fetchMock.mockImplementation((_url, init) => init?.method === "POST" ? Promise.resolve(new Response(null, { status: 204 })) : get.promise);
    render(<SmallModelsInterest {...props(true)} calc={productionCalc} />); clickRegister();
    await screen.findByText(confirmation);
    await act(async () => get.resolve(Response.json(saved)));
    expect(screen.getByText(confirmation)).toBeInTheDocument();
    expect(screen.queryByRole("button", { name: buttonName })).not.toBeInTheDocument();
  });
});
