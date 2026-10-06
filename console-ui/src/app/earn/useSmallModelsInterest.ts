"use client";

import { useCallback, useEffect, useRef, useState } from "react";
import { readSmallModelsInterest, registerSmallModelsInterest, type InterestHardware } from "@/lib/api/interest";

const PENDING_KEY = "darkbloom.smallModelsInterest.pending.v1";
const PENDING_TTL_MS = 15 * 60 * 1000;
const REQUEST_TIMEOUT_MS = 10_000;

interface PendingInterest {
  hardware: InterestHardware;
  accountId: string | null;
  armed: boolean;
  at: number;
}

function readPending(): PendingInterest | null {
  if (typeof window === "undefined") return null;
  try {
    const value = JSON.parse(window.localStorage.getItem(PENDING_KEY) || "null");
    if (!value || typeof value.at !== "number" || value.at > Date.now() ||
        Date.now() - value.at > PENDING_TTL_MS || typeof value.armed !== "boolean" ||
        (value.accountId !== null && typeof value.accountId !== "string") ||
        typeof value.hardware?.mac_type !== "string" || typeof value.hardware?.chip !== "string" ||
        !Number.isInteger(value.hardware?.ram_gb)) return null;
    // A reloaded page may offer a retry, but browser storage cannot renew consent.
    // This also makes a stale readable marker harmless if cancellation cannot write.
    return { ...value, armed: false };
  } catch { return null; }
}

function sameHardware(a: InterestHardware, b: InterestHardware) {
  return a.mac_type === b.mac_type && a.chip === b.chip && a.ram_gb === b.ram_gb;
}

export interface InterestAuth {
  authenticated: boolean;
  ready: boolean;
  accountId: string | null;
  getAccessToken: () => Promise<string | null>;
  login: () => void;
}

/** Local storage retains only a short-lived intent. Server acknowledgment is authoritative. */
export function useSmallModelsInterest(hardware: InterestHardware, auth: InterestAuth, onRegistered: (hardware: InterestHardware) => void) {
  const { authenticated, ready, accountId, getAccessToken, login } = auth;
  const [pending, setPending] = useState<PendingInterest | null>(null);
  const [confirmed, setConfirmed] = useState<{ accountId: string; hardware: InterestHardware } | null>(null);
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const writeGeneration = useRef(0);

  useEffect(() => { setPending(readPending()); }, []);

  const updatePending = useCallback((value: PendingInterest | null) => {
    setPending(value);
    try {
      if (value?.armed) window.localStorage.setItem(PENDING_KEY, JSON.stringify({ ...value, armed: false }));
      else window.localStorage.removeItem(PENDING_KEY);
    } catch { /* Registration still works when browser storage is unavailable. */ }
  }, []);

  useEffect(() => {
    if (!pending?.armed) return;
    const timeout = window.setTimeout(() => updatePending({ ...pending, armed: false }),
      Math.max(0, pending.at + PENDING_TTL_MS - Date.now()));
    return () => window.clearTimeout(timeout);
  }, [pending, updatePending]);

  useEffect(() => {
    setConfirmed(null);
    if (!ready || !authenticated || !accountId) return;
    const controller = new AbortController();
    const generation = writeGeneration.current;
    const timeout = window.setTimeout(() => controller.abort(), REQUEST_TIMEOUT_MS);
    readSmallModelsInterest(getAccessToken, controller.signal).then((record) => {
      if (record && !controller.signal.aborted && generation === writeGeneration.current) setConfirmed({ accountId, hardware: record });
      return undefined;
    }).catch(() => { /* A failed read never prevents an explicit, idempotent retry. */ });
    return () => { controller.abort(); window.clearTimeout(timeout); };
  }, [ready, authenticated, accountId, getAccessToken]);

  useEffect(() => {
    if (!pending?.armed) return;
    // An intent created by A must never be submitted using B's session or after logout.
    if (Date.now() - pending.at > PENDING_TTL_MS ||
        (ready && pending.accountId !== null && (!authenticated || pending.accountId !== accountId))) {
      updatePending({ ...pending, armed: false });
      setSaving(false);
      return;
    }
    if (!ready || !authenticated || !accountId) return;
    if (pending.accountId === null) {
      updatePending({ ...pending, accountId });
      return;
    }
    const controller = new AbortController();
    writeGeneration.current += 1;
    setSaving(true);
    const fail = (message: string) => {
      setError(message);
      setSaving(false);
      updatePending({ ...pending, armed: false });
    };
    const timeout = window.setTimeout(() => {
      controller.abort();
      fail("Registration timed out. Please try again.");
    }, REQUEST_TIMEOUT_MS);
    registerSmallModelsInterest(getAccessToken, pending.hardware, controller.signal).then(() => {
      if (controller.signal.aborted) return;
      setConfirmed({ accountId, hardware: pending.hardware });
      setSaving(false);
      setError(null);
      updatePending(null);
      try { onRegistered(pending.hardware); } catch { /* Analytics cannot undo acknowledgment. */ }
      return undefined;
    }).catch((cause: unknown) => {
      if (!controller.signal.aborted) fail(cause instanceof Error ? cause.message : "We couldn't save your interest. Please try again.");
    });
    return () => { controller.abort(); window.clearTimeout(timeout); };
  }, [pending, ready, authenticated, accountId, getAccessToken, updatePending, onRegistered]);

  const register = () => {
    if (!ready || saving || pending?.armed) return;
    writeGeneration.current += 1;
    setError(null);
    updatePending({ hardware, accountId: authenticated ? accountId : null, armed: true, at: Date.now() });
    if (!authenticated) login();
  };
  const cancel = () => {
    if (pending) updatePending({ ...pending, armed: false });
    setSaving(false);
    setError(null);
  };

  return {
    registered: authenticated && accountId === confirmed?.accountId && !!confirmed && sameHardware(hardware, confirmed.hardware),
    waitingForLogin: !!pending?.armed && !saving,
    saving, error, register, cancel,
  };
}
