// @vitest-environment jsdom
import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import {
  PROVIDER_WAITLIST_STORAGE_KEY,
  ProviderWaitlistForm,
} from "./ProviderWaitlistForm";

vi.mock("next/navigation", () => ({
  useSearchParams: () => new URLSearchParams(),
}));

vi.mock("@/lib/google-analytics", () => ({
  trackEvent: vi.fn(),
}));

const OTHER_MACHINE_LABEL = "Other machine";
const CUSTOM_MACHINE = "M6 developer kit";
const TEST_EMAIL = "owner@example.com";
const SUBMIT_LABEL = "Register hardware interest";
const CONFIRMATION_MESSAGE = "Hardware interest saved";
const REGISTERED_AT = "2026-08-25T12:00:00.000Z";

describe("ProviderWaitlistForm", () => {
  beforeEach(() => {
    window.localStorage.clear();
    vi.unstubAllGlobals();
  });

  afterEach(() => {
    vi.restoreAllMocks();
  });

  it("offers Others Machines and reveals its required text box", () => {
    render(<ProviderWaitlistForm />);

    expect(
      screen.getByRole("option", { name: "Others Machines" })
    ).toBeInTheDocument();
    expect(
      screen.queryByLabelText(OTHER_MACHINE_LABEL)
    ).not.toBeInTheDocument();
    fireEvent.change(screen.getByLabelText("Apple silicon chip"), {
      target: { value: "other" },
    });

    const otherMachine = screen.getByLabelText(OTHER_MACHINE_LABEL);
    expect(otherMachine).toBeRequired();
    expect(otherMachine).toHaveAttribute("maxlength", "160");
  });

  it("submits the custom machine and persists non-email confirmation state", async () => {
    const fetchMock = vi.fn().mockResolvedValue({
      ok: true,
      status: 200,
      headers: new Headers(),
      json: vi.fn().mockResolvedValue({ registered: true }),
    });
    vi.stubGlobal("fetch", fetchMock);
    render(<ProviderWaitlistForm />);

    fireEvent.change(screen.getByLabelText("Email"), {
      target: { value: TEST_EMAIL },
    });
    fireEvent.change(screen.getByLabelText("Apple silicon chip"), {
      target: { value: "other" },
    });
    fireEvent.change(screen.getByLabelText(OTHER_MACHINE_LABEL), {
      target: { value: CUSTOM_MACHINE },
    });
    fireEvent.change(screen.getByLabelText("Unified memory"), {
      target: { value: "64" },
    });
    fireEvent.change(screen.getByLabelText(/GPU cores/), {
      target: { value: "40" },
    });
    fireEvent.click(
      screen.getByLabelText(/I agree to store my email/)
    );
    fireEvent.submit(
      screen.getByRole("button", {
        name: SUBMIT_LABEL,
      }).closest("form")!
    );

    await waitFor(() => {
      expect(
        screen.getByText(CONFIRMATION_MESSAGE)
      ).toBeInTheDocument();
    });
    expect(screen.getByRole("status")).toHaveAttribute("aria-live", "polite");
    expect(
      screen.getByText(/provider capacity planning/)
    ).toBeInTheDocument();

    expect(fetchMock.mock.calls[0][0]).toBe(
      "https://api.darkbloom.dev/v1/provider-waitlist"
    );
    const request = fetchMock.mock.calls[0][1] as RequestInit;
    expect(JSON.parse(request.body as string)).toMatchObject({
      email: TEST_EMAIL,
      chip: "other",
      memory_gb: 64,
      gpu_cores: 40,
      other_machine: CUSTOM_MACHINE,
      consent: true,
    });
    const stored = window.localStorage.getItem(PROVIDER_WAITLIST_STORAGE_KEY);
    expect(stored).toContain(CUSTOM_MACHINE);
    expect(stored).not.toContain(TEST_EMAIL);
  });

  it("restores the confirmation state from local storage", async () => {
    window.localStorage.setItem(
      PROVIDER_WAITLIST_STORAGE_KEY,
      JSON.stringify({
        chip: "M4 Max",
        memoryGB: 128,
        otherMachine: "",
        registeredAt: REGISTERED_AT,
      })
    );

    render(<ProviderWaitlistForm />);

    expect(
      await screen.findByText(CONFIRMATION_MESSAGE)
    ).toBeInTheDocument();
    expect(screen.getByText("M4 Max")).toBeInTheDocument();
    expect(screen.getByText("128 GB")).toBeInTheDocument();
  });

  it.each([
    {
      chip: { name: "M4 Max" },
      memoryGB: 128,
      otherMachine: "",
      registeredAt: REGISTERED_AT,
    },
    {
      chip: "M4 Max",
      memoryGB: "128",
      otherMachine: "",
      registeredAt: REGISTERED_AT,
    },
    {
      chip: "M4 Max",
      memoryGB: 128,
      otherMachine: "",
      registeredAt: { date: "2026-08-25" },
    },
  ])("discards structurally invalid stored registration %#", (stored) => {
    window.localStorage.setItem(
      PROVIDER_WAITLIST_STORAGE_KEY,
      JSON.stringify(stored)
    );

    render(<ProviderWaitlistForm />);

    expect(
      screen.getByRole("button", { name: SUBMIT_LABEL })
    ).toBeInTheDocument();
    expect(
      window.localStorage.getItem(PROVIDER_WAITLIST_STORAGE_KEY)
    ).toBeNull();
  });

  it("renders the form when browser storage is blocked", () => {
    vi.spyOn(Storage.prototype, "getItem").mockImplementation(() => {
      throw new DOMException("blocked", "SecurityError");
    });

    expect(() => render(<ProviderWaitlistForm />)).not.toThrow();
    expect(
      screen.getByRole("button", { name: SUBMIT_LABEL })
    ).toBeInTheDocument();
  });

  it("keeps API success when browser storage cannot be written", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn().mockResolvedValue({
        ok: true,
        status: 200,
        headers: new Headers(),
        json: vi.fn().mockResolvedValue({ registered: true }),
      })
    );
    render(<ProviderWaitlistForm />);
    vi.spyOn(Storage.prototype, "setItem").mockImplementation(() => {
      throw new DOMException("full", "QuotaExceededError");
    });

    fireEvent.change(screen.getByLabelText("Email"), {
      target: { value: TEST_EMAIL },
    });
    fireEvent.click(
      screen.getByLabelText(/I agree to store my email/)
    );
    fireEvent.submit(
      screen.getByRole("button", {
        name: SUBMIT_LABEL,
      }).closest("form")!
    );

    expect(
      await screen.findByText(CONFIRMATION_MESSAGE)
    ).toBeInTheDocument();
    expect(screen.queryByRole("alert")).not.toBeInTheDocument();
  });

  it("shows the rounded Retry-After delay for rate limiting", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn().mockResolvedValue({
        ok: false,
        status: 429,
        headers: new Headers({ "Retry-After": "50" }),
        json: vi.fn().mockResolvedValue({
          error: { message: "too many provider waitlist registrations" },
        }),
      })
    );
    render(<ProviderWaitlistForm />);

    fireEvent.change(screen.getByLabelText("Email"), {
      target: { value: TEST_EMAIL },
    });
    fireEvent.click(
      screen.getByLabelText(/I agree to store my email/)
    );
    fireEvent.submit(
      screen.getByRole("button", { name: SUBMIT_LABEL }).closest("form")!
    );

    expect(await screen.findByRole("alert")).toHaveTextContent(
      "Too many attempts. Try again in 50 seconds."
    );
  });

  it("recovers from a bounded request timeout", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn().mockRejectedValue(new DOMException("timed out", "TimeoutError"))
    );
    render(<ProviderWaitlistForm />);

    fireEvent.change(screen.getByLabelText("Email"), {
      target: { value: TEST_EMAIL },
    });
    fireEvent.click(screen.getByLabelText(/I agree to store my email/));
    fireEvent.submit(
      screen.getByRole("button", { name: SUBMIT_LABEL }).closest("form")!
    );

    expect(await screen.findByRole("alert")).toHaveTextContent(
      "Registration timed out. Please try again."
    );
    expect(
      screen.getByRole("button", { name: SUBMIT_LABEL })
    ).not.toBeDisabled();
  });
});
