"use client";

import { useEffect, useState } from "react";
import { useToastStore } from "@/hooks/useToast";
import { healthCheck } from "@/lib/api";
import { STORAGE_KEYS } from "@/lib/constants";
import { apiExampleUrl } from "@/lib/api-example-url";
import { clearCoordinatorKeyCache, getCoordinatorKey, isEncryptionEnabled, setEncryptionEnabled } from "@/lib/encryption";

export function useConsoleSettings() {
  const addToast = useToastStore((state) => state.addToast);
  const [exampleUrl, setExampleUrl] = useState("");
  const [savedUrl, setSavedUrl] = useState("");
  const [saved, setSaved] = useState(false);
  const [healthStatus, setHealthStatus] = useState<"idle" | "checking" | "ok" | "error">("idle");
  const [healthInfo, setHealthInfo] = useState("");
  const [encryptToCoord, setEncryptToCoord] = useState(false);
  const [encStatus, setEncStatus] = useState<"idle" | "checking" | "ok" | "unavailable" | "error">("idle");
  const [encInfo, setEncInfo] = useState("");

  useEffect(() => {
    const url = apiExampleUrl();
    setExampleUrl(url);
    setSavedUrl(url);
    setEncryptToCoord(isEncryptionEnabled());
  }, []);

  const updateExampleUrl = (value: string) => {
    setExampleUrl(value);
    setSaved(false);
  };

  const handleSave = () => {
    const normalized = exampleUrl.trim().replace(/\/$/, "");
    try {
      const url = new URL(normalized);
      if (!["http:", "https:"].includes(url.protocol) || url.username || url.password || url.search || url.hash) throw new Error("Invalid URL");
    } catch {
      addToast("Enter an HTTP or HTTPS base URL without credentials, a query, or a fragment.", "error");
      return;
    }
    localStorage.setItem(STORAGE_KEYS.apiExampleUrl, normalized);
    setExampleUrl(normalized);
    setSavedUrl(normalized);
    setSaved(true);
    addToast("API example URL saved", "success");
  };

  const handleEncryptionToggle = async (enabled: boolean) => {
    setEncryptToCoord(enabled);
    setEncryptionEnabled(enabled);
    if (!enabled) {
      setEncStatus("idle");
      setEncInfo("");
      clearCoordinatorKeyCache();
      addToast("Encryption to coordinator disabled", "success");
      return;
    }
    setEncStatus("checking");
    try {
      const key = await getCoordinatorKey(true);
      setEncStatus("ok");
      setEncInfo(key.kid);
      addToast("Encryption to coordinator enabled", "success");
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      setEncStatus(message.includes("not configured") ? "unavailable" : "error");
      setEncInfo(message);
    }
  };

  const handleHealthCheck = async () => {
    setHealthStatus("checking");
    try {
      const result = await healthCheck();
      setHealthStatus("ok");
      setHealthInfo(`Connected, ${result.providers ?? 0} provider${result.providers === 1 ? "" : "s"} online`);
    } catch (error) {
      setHealthStatus("error");
      setHealthInfo(error instanceof Error ? error.message : "Connection check failed. Try again.");
    }
  };

  return { exampleUrl, saved, hasChanges: exampleUrl !== savedUrl, updateExampleUrl, handleSave, healthStatus, healthInfo, handleHealthCheck, encryptToCoord, encStatus, encInfo, handleEncryptionToggle };
}
