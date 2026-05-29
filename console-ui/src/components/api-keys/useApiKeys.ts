"use client";

import { useCallback, useEffect, useState } from "react";
import { useAuth } from "@/hooks/useAuth";
import { useToastStore } from "@/hooks/useToast";
import { trackEvent } from "@/lib/google-analytics";
import {
  createApiKey,
  deleteApiKey,
  fetchModels,
  listApiKeys,
  rotateApiKey,
  updateApiKey,
  type ApiKey,
  type CreatedKey,
  type UpdateKeyBody,
} from "@/lib/api";
import { API_KEY_STORAGE, CONSOLE_KEY_ID_STORAGE } from "./constants";

export interface UseApiKeys {
  authenticated: boolean;
  login: () => void;
  keys: ApiKey[];
  models: string[];
  loading: boolean;
  error: string | null;
  submitting: boolean;
  busyId: string | null;
  consoleKeyId: string | null;
  reload: () => Promise<void>;
  /** Create a key. Returns the once-only secret, or null on error. */
  createKey: (body: UpdateKeyBody) => Promise<CreatedKey | null>;
  /** Update a key's limits/name/disabled. Returns true on success. */
  editKey: (id: string, body: UpdateKeyBody) => Promise<boolean>;
  /** Toggle a key's disabled state. */
  toggleKey: (key: ApiKey) => Promise<void>;
  /** Rotate a key. Returns the new secret + whether it was the console key. */
  rotateKey: (key: ApiKey) => Promise<{ created: CreatedKey; wasConsole: boolean } | null>;
  /** Permanently delete a key. Returns true on success. */
  deleteKey: (key: ApiKey) => Promise<boolean>;
  /** Adopt a freshly created secret as this console's active key. */
  adoptConsoleKey: (created: CreatedKey) => void;
}

// useApiKeys owns all server interaction and the console-key localStorage
// bookkeeping. UI/modal state lives in the component that consumes it.
export function useApiKeys({ onConsoleKeyChange }: { onConsoleKeyChange?: (key: string) => void }): UseApiKeys {
  const { authenticated, login, getAccessToken } = useAuth();
  const addToast = useToastStore((s) => s.addToast);

  const [keys, setKeys] = useState<ApiKey[]>([]);
  const [models, setModels] = useState<string[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [submitting, setSubmitting] = useState(false);
  const [busyId, setBusyId] = useState<string | null>(null);
  const [consoleKeyId, setConsoleKeyId] = useState<string | null>(null);

  useEffect(() => {
    if (typeof window !== "undefined") {
      setConsoleKeyId(localStorage.getItem(CONSOLE_KEY_ID_STORAGE));
    }
  }, []);

  const requireToken = useCallback(async (): Promise<string | null> => {
    const token = await getAccessToken().catch(() => null);
    if (!token) addToast("Please sign in to manage API keys", "error");
    return token;
  }, [getAccessToken, addToast]);

  const fetchKeys = useCallback(async (token: string) => {
    setKeys(await listApiKeys(token));
  }, []);

  const reload = useCallback(async () => {
    setLoading(true);
    setError(null);
    try {
      const token = await getAccessToken().catch(() => null);
      if (!token) {
        setKeys([]);
        setError("Sign in to view your API keys.");
        return;
      }
      await fetchKeys(token);
    } catch (e) {
      setError((e as Error).message);
    } finally {
      setLoading(false);
    }
  }, [getAccessToken, fetchKeys]);

  useEffect(() => {
    if (!authenticated) {
      setLoading(false);
      setKeys([]);
      return;
    }
    void reload();
  }, [authenticated, reload]);

  useEffect(() => {
    let cancelled = false;
    void (async () => {
      try {
        const ms = await fetchModels();
        if (!cancelled) setModels(ms.map((m) => m.id).filter(Boolean));
      } catch {
        // Models are optional — the form falls back to a free-text input.
      }
    })();
    return () => {
      cancelled = true;
    };
  }, []);

  // Point the console's active key (and its tracked id) at a secret.
  //
  // The console is a browser app that calls the inference API with a bearer
  // key, so its one active key necessarily lives in localStorage (same place
  // useAuth auto-provisions it). This is the pre-existing, accepted SEC-003
  // tradeoff — not new exposure from multi-key management. CodeQL flags the
  // write below ("clear-text storage"); moving off localStorage would require
  // re-architecting console auth to an HttpOnly-cookie/server-session model
  // (tracked separately by SEC-003), out of scope here.
  const pointConsoleKeyAt = useCallback(
    (created: CreatedKey) => {
      if (typeof window === "undefined") return;
      localStorage.setItem(API_KEY_STORAGE, created.key);
      localStorage.setItem(CONSOLE_KEY_ID_STORAGE, created.data.id);
      setConsoleKeyId(created.data.id);
      onConsoleKeyChange?.(created.key);
    },
    [onConsoleKeyChange],
  );

  const adoptConsoleKey = useCallback(
    (created: CreatedKey) => {
      pointConsoleKeyAt(created);
      addToast("This key is now your console key", "success");
    },
    [pointConsoleKeyAt, addToast],
  );

  const createKey = useCallback(
    async (body: UpdateKeyBody): Promise<CreatedKey | null> => {
      const token = await requireToken();
      if (!token) return null;
      setSubmitting(true);
      try {
        const created = await createApiKey(token, body);
        trackEvent("key_create", { has_limit: body.limit_usd != null });
        await fetchKeys(token);
        return created;
      } catch (e) {
        addToast((e as Error).message, "error");
        return null;
      } finally {
        setSubmitting(false);
      }
    },
    [requireToken, fetchKeys, addToast],
  );

  const editKey = useCallback(
    async (id: string, body: UpdateKeyBody): Promise<boolean> => {
      const token = await requireToken();
      if (!token) return false;
      setSubmitting(true);
      try {
        await updateApiKey(token, id, body);
        trackEvent("key_update");
        addToast("Key updated", "success");
        await fetchKeys(token);
        return true;
      } catch (e) {
        addToast((e as Error).message, "error");
        return false;
      } finally {
        setSubmitting(false);
      }
    },
    [requireToken, fetchKeys, addToast],
  );

  const toggleKey = useCallback(
    async (key: ApiKey) => {
      const token = await requireToken();
      if (!token) return;
      setBusyId(key.id);
      try {
        await updateApiKey(token, key.id, { disabled: !key.disabled });
        addToast(key.disabled ? "Key enabled" : "Key disabled", "success");
        await fetchKeys(token);
      } catch (e) {
        addToast((e as Error).message, "error");
      } finally {
        setBusyId(null);
      }
    },
    [requireToken, fetchKeys, addToast],
  );

  const rotateKey = useCallback(
    async (key: ApiKey): Promise<{ created: CreatedKey; wasConsole: boolean } | null> => {
      const token = await requireToken();
      if (!token) return null;
      setBusyId(key.id);
      try {
        const created = await rotateApiKey(token, key.id);
        trackEvent("key_rotate");
        const wasConsole = consoleKeyId === key.id;
        if (wasConsole) {
          // Rotation mints a NEW key id and deletes the old one, so re-point the
          // console-key mapping at the new id as well as the new secret —
          // otherwise the badge and future console-key actions track a deleted id.
          pointConsoleKeyAt(created);
        }
        await fetchKeys(token);
        return { created, wasConsole };
      } catch (e) {
        addToast((e as Error).message, "error");
        return null;
      } finally {
        setBusyId(null);
      }
    },
    [requireToken, fetchKeys, addToast, consoleKeyId, pointConsoleKeyAt],
  );

  const deleteKey = useCallback(
    async (key: ApiKey): Promise<boolean> => {
      const token = await requireToken();
      if (!token) return false;
      setBusyId(key.id);
      try {
        await deleteApiKey(token, key.id);
        trackEvent("key_delete");
        if (consoleKeyId === key.id && typeof window !== "undefined") {
          localStorage.removeItem(API_KEY_STORAGE);
          localStorage.removeItem(CONSOLE_KEY_ID_STORAGE);
          setConsoleKeyId(null);
          onConsoleKeyChange?.("");
          window.dispatchEvent(new Event("darkbloom-key-expired"));
          addToast("Console key revoked — a new one will be provisioned automatically", "info");
        } else {
          addToast("Key revoked", "success");
        }
        await fetchKeys(token);
        return true;
      } catch (e) {
        addToast((e as Error).message, "error");
        return false;
      } finally {
        setBusyId(null);
      }
    },
    [requireToken, fetchKeys, addToast, consoleKeyId, onConsoleKeyChange],
  );

  return {
    authenticated,
    login,
    keys,
    models,
    loading,
    error,
    submitting,
    busyId,
    consoleKeyId,
    reload,
    createKey,
    editKey,
    toggleKey,
    rotateKey,
    deleteKey,
    adoptConsoleKey,
  };
}
