import { createServer, type Server, type ServerResponse } from "node:http";
import { act, cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react";
import { afterEach, describe, expect, it, vi } from "vitest";
import { ProviderDashboard } from "./ProviderDashboard";
import { makeProvider } from "./testFixtures";

vi.mock("@/hooks/useAuth", () => ({
  useAuth: () => ({
    ready: true,
    authenticated: true,
    user: { id: "local-test-account" },
    login: () => {},
    getAccessToken: async () => "local-test-token",
  }),
}));

let server: Server | undefined;

afterEach(async () => {
  cleanup();
  vi.unstubAllGlobals();
  if (server?.listening) {
    const stopped = new Promise<void>((resolve, reject) => {
      server!.close((error) => error ? reject(error) : resolve());
    });
    server.closeAllConnections();
    await stopped;
    server = undefined;
  }
});

describe("fleet loading over HTTP", () => {
  it.each(["headers", "body"])("keeps loading machines while summary %s are pending", async (pendingPart) => {
    let providerRequests = 0;
    let summaryRequests = 0;
    let summaryResponse: ServerResponse | undefined;
    server = createServer((request, response) => {
      if (request.url === "/api/me/providers") {
        providerRequests++;
        response.writeHead(200, { "Content-Type": "application/json" });
        response.end(JSON.stringify({ providers: [makeProvider({
          id: `machine-${providerRequests}`,
          hardware: { chip_name: `Test Chip ${providerRequests}` },
        })] }));
      } else if (request.url === "/api/me/summary") {
        summaryRequests++;
        summaryResponse = response;
        if (pendingPart === "body") {
          response.writeHead(200, { "Content-Type": "application/json" });
          response.flushHeaders();
        }
      } else {
        response.writeHead(404).end();
      }
    });
    await new Promise<void>((resolve, reject) => {
      server!.once("error", reject);
      server!.listen(0, "127.0.0.1", resolve);
    });
    const address = server.address();
    if (!address || typeof address === "string") throw new Error("Missing loopback port");
    const nativeFetch = globalThis.fetch;
    vi.stubGlobal("fetch", (url: string, options: RequestInit) =>
      nativeFetch(`http://127.0.0.1:${address.port}${url}`, options));

    render(<ProviderDashboard />);
    await waitFor(() => expect(providerRequests).toBe(1));
    await waitFor(() => expect(summaryRequests).toBe(1));
    await waitFor(() => expect(screen.getByRole("heading", { name: "Fleet" })).toBeInTheDocument());
    expect(screen.getByText("Test Chip 1")).toBeInTheDocument();
    const refresh = screen.getByRole("button", { name: "Refresh" });
    expect(refresh).toBeEnabled();

    fireEvent.click(refresh);
    await waitFor(() => expect(screen.getByText("Test Chip 2")).toBeInTheDocument());
    expect(refresh).toBeEnabled();
    expect(providerRequests).toBe(2);
    expect(summaryRequests).toBe(1);

    await act(async () => {
      if (!summaryResponse) throw new Error("Summary request was not received");
      if (!summaryResponse.headersSent) summaryResponse.writeHead(200, { "Content-Type": "application/json" });
      summaryResponse.end(JSON.stringify({ account_id: "local-test-account", lifetime_micro_usd: 1_000_000 }));
    });
    await waitFor(() => expect(screen.getByText("$1.00")).toBeInTheDocument());
  });
});
