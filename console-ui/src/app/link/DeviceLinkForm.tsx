"use client";

import { useState, useCallback } from "react";
import { useAuthContext } from "@/components/providers/PrivyClientProvider";
import { trackEvent } from "@/lib/google-analytics";
import { useTranslations } from "next-intl";

const COORDINATOR_URL =
  process.env.NEXT_PUBLIC_COORDINATOR_URL ||
  "https://api.darkbloom.dev";

type LinkStatus = "idle" | "submitting" | "success" | "error";

export function DeviceLinkForm() {
  const { ready, authenticated, login, getAccessToken, user } = useAuthContext();
  const [code, setCode] = useState("");
  const [status, setStatus] = useState<LinkStatus>("idle");
  const [errorMsg, setErrorMsg] = useState("");
  const t = useTranslations("DeviceLinkForm");

  const handleSubmit = useCallback(
    async (e: React.FormEvent) => {
      e.preventDefault();
      if (!code.trim()) return;

      trackEvent("device_link_submit", {
        flow: "device_link_form",
      });
      setStatus("submitting");
      setErrorMsg("");

      try {
        const token = await getAccessToken();
        if (!token) {
          trackEvent("device_link_error", {
            flow: "device_link_form",
            reason: "missing_auth_token",
          });
          setErrorMsg(t("missingToken"));
          setStatus("error");
          return;
        }

        const res = await fetch(`${COORDINATOR_URL}/v1/device/approve`, {
          method: "POST",
          headers: {
            "Content-Type": "application/json",
            Authorization: `Bearer ${token}`,
          },
          body: JSON.stringify({ user_code: code.trim().toUpperCase() }),
        });

        const data = await res.json();

        if (!res.ok) {
          trackEvent("device_link_error", {
            flow: "device_link_form",
            reason: "approval_failed",
          });
          setErrorMsg(
            data?.error?.message || data?.message || t("failed")
          );
          setStatus("error");
          return;
        }

        trackEvent("device_link_success", {
          flow: "device_link_form",
        });
        setStatus("success");
      } catch {
        trackEvent("device_link_error", {
          flow: "device_link_form",
          reason: "network_error",
        });
        setErrorMsg(t("networkError"));
        setStatus("error");
      }
    },
    [code, getAccessToken, t]
  );

  // Format input as XXXX-XXXX
  const handleCodeChange = (value: string) => {
    const clean = value.replace(/[^A-Za-z0-9]/g, "").toUpperCase();
    if (clean.length <= 4) {
      setCode(clean);
    } else {
      setCode(clean.slice(0, 4) + "-" + clean.slice(4, 8));
    }
  };

  if (!ready) {
    return (
      <div className="bg-bg-white rounded-2xl border border-border-dim shadow-md p-8 text-center">
        <div className="animate-pulse text-text-tertiary">{t("loading")}</div>
      </div>
    );
  }

  // Success state
  if (status === "success") {
    return (
      <div className="bg-bg-white rounded-2xl border border-border-dim shadow-md p-8 text-center">
        <div className="w-16 h-16 bg-teal-light border-2 border-teal rounded-full flex items-center justify-center mx-auto mb-4">
          <svg
            className="w-8 h-8 text-teal"
            fill="none"
            viewBox="0 0 24 24"
            stroke="currentColor"
          >
            <path
              strokeLinecap="round"
              strokeLinejoin="round"
              strokeWidth={2.5}
              d="M5 13l4 4L19 7"
            />
          </svg>
        </div>
        <h2 className="text-2xl font-semibold text-ink mb-2">
          {t("successTitle")}
        </h2>
        <p className="text-text-secondary">
          {t("successBody")}
        </p>
        <p className="text-text-tertiary text-sm mt-4">
          {t("successClose")}
        </p>
      </div>
    );
  }

  // Not authenticated — show login prompt
  if (!authenticated) {
    return (
      <div className="bg-bg-white rounded-2xl border border-border-dim shadow-md p-8 text-center">
        <p className="text-text-secondary mb-6">
          {t("signInPrompt")}
        </p>
        <button
          onClick={() => {
            trackEvent("login_cta_clicked", {
              source: "device_link_form",
            });
            login();
          }}
          className="w-full px-6 py-3 bg-coral text-white rounded-xl font-bold border border-border-dim
                     hover:opacity-90 transition-all"
        >
          {t("signIn")}
        </button>
      </div>
    );
  }

  // Authenticated — show code entry form
  return (
    <div className="bg-bg-white rounded-2xl border border-border-dim shadow-md p-8">
      <div className="text-sm text-text-secondary mb-6 text-center">
        {t("signedInAs")}{" "}
        <span className="font-semibold text-ink">
          {(user as { email?: { address?: string }; wallet?: { address?: string } })?.email?.address ||
            (user as { wallet?: { address?: string } })?.wallet?.address ||
            t("yourAccount")}
        </span>
      </div>

      <form onSubmit={handleSubmit} className="space-y-6">
        <div>
          <label
            htmlFor="device-code"
            className="block text-sm font-semibold text-ink mb-2"
          >
            {t("codeLabel")}
          </label>
          <input
            id="device-code"
            type="text"
            value={code}
            onChange={(e) => handleCodeChange(e.target.value)}
            placeholder="XXXX-XXXX"
            maxLength={9}
            className="w-full px-4 py-3 text-center text-2xl font-mono tracking-widest
                       bg-bg-primary border border-border-dim rounded-xl
                       focus:border-coral outline-none transition-colors
                       placeholder:text-text-tertiary/40"
            autoFocus
            autoComplete="off"
          />
        </div>

        {status === "error" && (
          <div className="text-accent-red text-sm bg-accent-red-dim border-2 border-accent-red/20 rounded-lg p-3">
            {errorMsg}
          </div>
        )}

        <button
          type="submit"
          disabled={code.replace("-", "").length !== 8 || status === "submitting"}
          className="w-full px-6 py-3 bg-coral text-white rounded-xl font-bold border border-border-dim
                     hover:opacity-90
                     transition-all disabled:opacity-40 disabled:cursor-not-allowed"
        >
          {status === "submitting" ? t("linking") : t("linkDevice")}
        </button>
      </form>

      <div className="mt-6 text-xs text-text-tertiary text-center">
        {t("run")}{" "}
        <code className="bg-bg-tertiary px-1.5 py-0.5 rounded font-mono text-coral border border-border-dim">
          darkbloom login
        </code>{" "}
        {t("runSuffix")}
      </div>
    </div>
  );
}
