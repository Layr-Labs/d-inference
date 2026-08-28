"use client";

import { HARDWARE_OPTIONS } from "@/app/earn/calc";
import { PUBLIC_COORDINATOR_URL } from "@/lib/coordinator-url";
import { trackEvent } from "@/lib/google-analytics";
import { Check, ClipboardList, LockKeyhole } from "lucide-react";
import { FormEvent, useEffect, useMemo, useState } from "react";
import { useSearchParams } from "next/navigation";

export const PROVIDER_WAITLIST_STORAGE_KEY =
  "darkbloom_provider_waitlist_registration_v1";

const OTHER_CHIP = "other";
const CHIP_OPTIONS = Array.from(
  HARDWARE_OPTIONS.reduce((options, hardware) => {
    const memory = options.get(hardware.chip) ?? new Set<number>();
    for (const memoryGB of hardware.ramOptions) memory.add(memoryGB);
    options.set(hardware.chip, memory);
    return options;
  }, new Map<string, Set<number>>())
).map(([chip, memory]) => ({
  chip,
  ramOptions: Array.from(memory).sort((a, b) => a - b),
}));
const ALL_MEMORY_OPTIONS = Array.from(
  new Set(CHIP_OPTIONS.flatMap((option) => option.ramOptions))
).sort((a, b) => a - b);

interface StoredRegistration {
  chip: string;
  memoryGB: number;
  gpuCores?: number;
  otherMachine: string;
  registeredAt: string;
}

interface APIErrorBody {
  error?: {
    message?: string;
  };
}

function isStoredRegistration(value: unknown): value is StoredRegistration {
  if (typeof value !== "object" || value === null) return false;
  const registration = value as Partial<StoredRegistration>;
  return (
    typeof registration.chip === "string" &&
    registration.chip.length > 0 &&
    typeof registration.memoryGB === "number" &&
    Number.isInteger(registration.memoryGB) &&
    registration.memoryGB >= 4 &&
    registration.memoryGB <= 1024 &&
    (registration.gpuCores === undefined ||
      (typeof registration.gpuCores === "number" &&
        Number.isInteger(registration.gpuCores) &&
        registration.gpuCores >= 0 &&
        registration.gpuCores <= 512)) &&
    typeof registration.otherMachine === "string" &&
    typeof registration.registeredAt === "string" &&
    !Number.isNaN(Date.parse(registration.registeredAt))
  );
}

function removeStoredRegistration() {
  try {
    window.localStorage.removeItem(PROVIDER_WAITLIST_STORAGE_KEY);
  } catch {
    // Browser storage is optional; the durable coordinator record is canonical.
  }
}

function readStoredRegistration(): StoredRegistration | null {
  try {
    const raw = window.localStorage.getItem(PROVIDER_WAITLIST_STORAGE_KEY);
    if (!raw) return null;
    const saved: unknown = JSON.parse(raw);
    if (isStoredRegistration(saved)) return saved;
  } catch {
    // Blocked or malformed browser storage must not break the public form.
  }
  removeStoredRegistration();
  return null;
}

function persistStoredRegistration(registration: StoredRegistration) {
  try {
    window.localStorage.setItem(
      PROVIDER_WAITLIST_STORAGE_KEY,
      JSON.stringify(registration)
    );
  } catch {
    // The API already persisted successfully; confirmation still renders.
  }
}

function submissionErrorMessage(error: unknown): string {
  if (error instanceof DOMException && error.name === "TimeoutError") {
    return "Registration timed out. Please try again.";
  }
  if (error instanceof Error) return error.message;
  return "Registration could not be saved. Please try again.";
}

function matchingChip(raw: string | null): string | null {
  if (!raw) return null;
  return (
    CHIP_OPTIONS.find(
      (option) => option.chip.toLowerCase() === raw.trim().toLowerCase()
    )?.chip ?? null
  );
}

function parseInitialMemory(raw: string | null, chip: string): number {
  const parsed = Number.parseInt(raw ?? "", 10);
  if (Number.isInteger(parsed) && parsed >= 4 && parsed <= 1024) {
    return parsed;
  }
  return (
    CHIP_OPTIONS.find((option) => option.chip === chip)?.ramOptions[0] ??
    ALL_MEMORY_OPTIONS[0]
  );
}

function parseInitialGPUCores(raw: string | null): number {
  const parsed = Number.parseInt(raw ?? "", 10);
  return Number.isInteger(parsed) && parsed >= 1 && parsed <= 512 ? parsed : 0;
}

export function ProviderWaitlistForm() {
  const searchParams = useSearchParams();
  const requestedChip = searchParams.get("chip");
  const knownInitialChip = matchingChip(requestedChip);
  const initialChip =
    knownInitialChip ?? (requestedChip ? OTHER_CHIP : CHIP_OPTIONS[0].chip);

  const [email, setEmail] = useState("");
  const [chip, setChip] = useState(initialChip);
  const [memoryGB, setMemoryGB] = useState(() =>
    parseInitialMemory(searchParams.get("memory_gb"), initialChip)
  );
  const [gpuCores, setGPUCores] = useState(() =>
    parseInitialGPUCores(searchParams.get("gpu_cores"))
  );
  const [otherMachine, setOtherMachine] = useState(
    knownInitialChip ? "" : requestedChip ?? ""
  );
  const [consent, setConsent] = useState(false);
  const [company, setCompany] = useState("");
  const [submitting, setSubmitting] = useState(false);
  const [registered, setRegistered] = useState(false);
  const [storedRegistration, setStoredRegistration] =
    useState<StoredRegistration | null>(null);
  const [error, setError] = useState("");

  useEffect(() => {
    const saved = readStoredRegistration();
    if (saved) {
      setStoredRegistration(saved);
      setRegistered(true);
    }
  }, []);

  const memoryOptions = useMemo(() => {
    const base =
      CHIP_OPTIONS.find((option) => option.chip === chip)?.ramOptions ??
      ALL_MEMORY_OPTIONS;
    return Array.from(new Set([...base, memoryGB])).sort((a, b) => a - b);
  }, [chip, memoryGB]);

  function changeChip(nextChip: string) {
    setChip(nextChip);
    if (nextChip !== OTHER_CHIP) {
      setOtherMachine("");
    }
    const nextMemoryOptions =
      CHIP_OPTIONS.find((option) => option.chip === nextChip)?.ramOptions ??
      ALL_MEMORY_OPTIONS;
    setMemoryGB(nextMemoryOptions[0]);
  }

  async function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    setError("");
    setSubmitting(true);

    try {
      const response = await fetch(
        `${PUBLIC_COORDINATOR_URL}/v1/provider-waitlist`,
        {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          signal: AbortSignal.timeout(10_000),
          body: JSON.stringify({
            email,
            chip,
            memory_gb: memoryGB,
            gpu_cores: gpuCores,
            other_machine: chip === OTHER_CHIP ? otherMachine : "",
            consent,
            company,
          }),
        }
      );
      if (!response.ok) {
        const body = (await response.json().catch(() => null)) as APIErrorBody | null;
        const retryAfter = response.headers.get("Retry-After");
        const fallback =
          response.status === 429 && retryAfter
            ? `Too many attempts. Try again in ${retryAfter} seconds.`
            : "Registration could not be saved. Please try again.";
        const message =
          response.status === 429 && retryAfter
            ? fallback
            : body?.error?.message || fallback;
        throw new Error(message);
      }

      const saved: StoredRegistration = {
        chip,
        memoryGB,
        gpuCores,
        otherMachine: chip === OTHER_CHIP ? otherMachine.trim() : "",
        registeredAt: new Date().toISOString(),
      };
      setStoredRegistration(saved);
      setRegistered(true);
      persistStoredRegistration(saved);
      trackEvent("provider_waitlist_registered", {
        chip: chip === OTHER_CHIP ? OTHER_CHIP : chip,
        memory_gb: memoryGB,
        gpu_cores: gpuCores,
      });
    } catch (submissionError) {
      setError(submissionErrorMessage(submissionError));
    } finally {
      setSubmitting(false);
    }
  }

  function resetRegistration() {
    removeStoredRegistration();
    setStoredRegistration(null);
    setRegistered(false);
    setError("");
  }

  if (registered && storedRegistration) {
    const machine =
      storedRegistration.chip === OTHER_CHIP
        ? storedRegistration.otherMachine
        : storedRegistration.chip;
    return (
      <div
        role="status"
        aria-live="polite"
        className="rounded-2xl border border-accent-green/25 bg-bg-secondary p-6 sm:p-8"
      >
        <div className="mb-5 flex h-11 w-11 items-center justify-center rounded-full bg-accent-green/10 text-accent-green">
          <Check size={22} strokeWidth={2.5} aria-hidden="true" />
        </div>
        <h2 className="text-xl font-semibold text-text-primary">
          Hardware interest saved
        </h2>
        <p className="mt-2 text-sm leading-relaxed text-text-secondary">
          We stored this registration for provider capacity planning.
        </p>
        <dl className="mt-6 grid grid-cols-2 gap-4 border-y border-border-dim py-4 text-sm">
          <div>
            <dt className="text-text-tertiary">Machine</dt>
            <dd className="mt-1 font-medium text-text-primary">{machine}</dd>
          </div>
          <div>
            <dt className="text-text-tertiary">Unified memory</dt>
            <dd className="mt-1 font-medium text-text-primary">
              {storedRegistration.memoryGB} GB
            </dd>
          </div>
          {Boolean(storedRegistration.gpuCores) && (
            <div>
              <dt className="text-text-tertiary">GPU cores</dt>
              <dd className="mt-1 font-medium text-text-primary">
                {storedRegistration.gpuCores}
              </dd>
            </div>
          )}
        </dl>
        <button
          type="button"
          onClick={resetRegistration}
          className="mt-5 text-sm font-medium text-accent-brand transition-colors hover:text-accent-brand-hover focus-ring"
        >
          Update this registration
        </button>
      </div>
    );
  }

  return (
    <form
      onSubmit={submit}
      className="rounded-2xl border border-border-default bg-bg-secondary p-6 shadow-sm sm:p-8"
    >
      <div className="mb-6">
        <div className="mb-3 flex items-center gap-2 text-xs font-medium uppercase tracking-[0.12em] text-accent-brand">
          <ClipboardList size={14} aria-hidden="true" />
          Hardware interest
        </div>
        <h2 className="text-xl font-semibold text-text-primary">
          Register your machine
        </h2>
        <p className="mt-2 text-sm leading-relaxed text-text-secondary">
          This records demand for future provider support; it does not create an
          active email notification subscription.
        </p>
      </div>

      <div className="space-y-5">
        <div>
          <label
            htmlFor="waitlist-email"
            className="mb-2 block text-sm font-medium text-text-primary"
          >
            Email
          </label>
          <input
            id="waitlist-email"
            name="email"
            type="email"
            autoComplete="email"
            required
            maxLength={254}
            value={email}
            onChange={(event) => setEmail(event.target.value)}
            placeholder="you@example.com"
            className="w-full rounded-lg border border-border-default bg-bg-primary px-3.5 py-3 text-sm text-text-primary outline-none transition-colors placeholder:text-text-tertiary focus:border-accent-brand focus:ring-2 focus:ring-accent-brand/15"
          />
        </div>

        <div className="grid gap-5 sm:grid-cols-2">
          <div>
            <label
              htmlFor="waitlist-chip"
              className="mb-2 block text-sm font-medium text-text-primary"
            >
              Apple silicon chip
            </label>
            <select
              id="waitlist-chip"
              name="chip"
              value={chip}
              onChange={(event) => changeChip(event.target.value)}
              className="w-full rounded-lg border border-border-default bg-bg-primary px-3.5 py-3 text-sm text-text-primary outline-none transition-colors focus:border-accent-brand focus:ring-2 focus:ring-accent-brand/15"
            >
              {CHIP_OPTIONS.map((option) => (
                <option key={option.chip} value={option.chip}>
                  {option.chip}
                </option>
              ))}
              <option value={OTHER_CHIP}>Others Machines</option>
            </select>
          </div>

          <div>
            <label
              htmlFor="waitlist-memory"
              className="mb-2 block text-sm font-medium text-text-primary"
            >
              Unified memory
            </label>
            <select
              id="waitlist-memory"
              name="memory_gb"
              value={memoryGB}
              onChange={(event) => setMemoryGB(Number(event.target.value))}
              className="w-full rounded-lg border border-border-default bg-bg-primary px-3.5 py-3 text-sm text-text-primary outline-none transition-colors focus:border-accent-brand focus:ring-2 focus:ring-accent-brand/15"
            >
              {memoryOptions.map((memory) => (
                <option key={memory} value={memory}>
                  {memory} GB
                </option>
              ))}
            </select>
          </div>
        </div>

        <div>
          <label
            htmlFor="waitlist-gpu-cores"
            className="mb-2 block text-sm font-medium text-text-primary"
          >
            GPU cores <span className="font-normal text-text-tertiary">(optional)</span>
          </label>
          <input
            id="waitlist-gpu-cores"
            name="gpu_cores"
            type="number"
            min={1}
            max={512}
            inputMode="numeric"
            value={gpuCores || ""}
            onChange={(event) =>
              setGPUCores(
                event.target.value === "" ? 0 : Number(event.target.value)
              )
            }
            placeholder="For example, 40"
            className="w-full rounded-lg border border-border-default bg-bg-primary px-3.5 py-3 text-sm text-text-primary outline-none transition-colors placeholder:text-text-tertiary focus:border-accent-brand focus:ring-2 focus:ring-accent-brand/15"
          />
          <p className="mt-1.5 text-xs text-text-tertiary">
            Improves matching for Max and Ultra variants.
          </p>
        </div>

        {chip === OTHER_CHIP && (
          <div>
            <label
              htmlFor="waitlist-other-machine"
              className="mb-2 block text-sm font-medium text-text-primary"
            >
              Other machine
            </label>
            <input
              id="waitlist-other-machine"
              name="other_machine"
              type="text"
              required
              maxLength={160}
              value={otherMachine}
              onChange={(event) => setOtherMachine(event.target.value)}
              placeholder="Mac model and chip, for example M6 developer kit"
              className="w-full rounded-lg border border-border-default bg-bg-primary px-3.5 py-3 text-sm text-text-primary outline-none transition-colors placeholder:text-text-tertiary focus:border-accent-brand focus:ring-2 focus:ring-accent-brand/15"
            />
          </div>
        )}

        <div
          className="absolute -left-[10000px] top-auto h-px w-px overflow-hidden"
          aria-hidden="true"
        >
          <label htmlFor="waitlist-company">Company website</label>
          <input
            id="waitlist-company"
            name="company"
            type="text"
            tabIndex={-1}
            autoComplete="off"
            value={company}
            onChange={(event) => setCompany(event.target.value)}
          />
        </div>

        <label className="flex cursor-pointer items-start gap-3 text-sm leading-relaxed text-text-secondary">
          <input
            type="checkbox"
            required
            checked={consent}
            onChange={(event) => setConsent(event.target.checked)}
            className="mt-1 h-4 w-4 shrink-0 accent-coral"
          />
          <span>
            I agree to store my email and hardware details for provider capacity
            planning.
          </span>
        </label>

        {error && (
          <p
            role="alert"
            className="rounded-lg border border-accent-red/20 bg-accent-red/10 px-3.5 py-3 text-sm text-accent-red"
          >
            {error}
          </p>
        )}

        <button
          type="submit"
          disabled={submitting}
          className="inline-flex w-full items-center justify-center rounded-lg bg-coral px-5 py-3 text-sm font-bold text-white transition-opacity hover:opacity-90 disabled:cursor-not-allowed disabled:opacity-50 focus-ring"
        >
          {submitting ? "Saving…" : "Register hardware interest"}
        </button>

        <p className="flex items-center justify-center gap-2 text-xs text-text-tertiary">
          <LockKeyhole size={13} aria-hidden="true" />
          Your email is stored only for provider capacity planning.
        </p>
      </div>
    </form>
  );
}
