"use client";

import { useState, useCallback } from "react";
import { useAuthContext } from "@/components/app-providers/PrivyClientProvider";
import { trackEvent } from "@/lib/google-analytics";

type LinkStatus = "idle" | "submitting" | "success" | "error";

export function DeviceLinkForm({ purpose = "provider" }: { purpose?: "provider" | "desktop_account" }) {
  const { ready, authenticated, login, getAccessToken, user } = useAuthContext();
  const desktopAccount = purpose === "desktop_account";
  const [code, setCode] = useState("");
  const [status, setStatus] = useState<LinkStatus>("idle");
  const [errorMsg, setErrorMsg] = useState("");

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
          setErrorMsg("Failed to get auth token. Please log in again.");
          setStatus("error");
          return;
        }

        const res = await fetch(`/api/device/approve`, {
          method: "POST",
          headers: {
            "Content-Type": "application/json",
            Authorization: `Bearer ${token}`,
          },
          body: JSON.stringify({ user_code: code.trim().toUpperCase(), purpose }),
        });

        const data = await res.json();

        if (!res.ok) {
          trackEvent("device_link_error", {
            flow: "device_link_form",
            reason: "approval_failed",
          });
          setErrorMsg(
            data?.error?.message || data?.message || "Failed to link device"
          );
          setStatus("error");
          return;
        }

        if (desktopAccount && data.purpose !== "desktop_account") {
          setErrorMsg("The coordinator did not confirm read-only desktop access. Please try again after it is updated.");
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
        setErrorMsg("Network error. Please check your connection.");
        setStatus("error");
      }
    },
    [code, desktopAccount, getAccessToken, purpose]
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
        <div className="animate-pulse text-text-tertiary">Loading...</div>
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
          {desktopAccount ? "Desktop Access Approved" : "Device Linked!"}
        </h2>
        <p className="text-text-secondary">
          {desktopAccount
            ? "Return to the app to view your Macs and earnings. Your provider configuration has not changed."
            : "Your provider is now connected to your account. Earnings will be credited automatically."}
        </p>
        {!desktopAccount && <>
          <p className="text-text-tertiary text-sm mt-4">Return to your terminal to finish starting the provider.</p>
          <a href="/providers" className="mt-6 inline-flex min-h-11 items-center rounded-lg bg-accent-brand px-5 text-sm font-medium text-white dark:text-bg-primary">Open your provider workspace</a>
        </>}
      </div>
    );
  }

  // Not authenticated — show login prompt
  if (!authenticated) {
    return (
      <div className="bg-bg-white rounded-2xl border border-border-dim shadow-md p-8 text-center">
        <p className="text-text-secondary mb-6">
          {desktopAccount
            ? "Sign in to your Darkbloom account to authorize read-only desktop access."
            : "Sign in to your Darkbloom account to link your device."}
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
          Sign In
        </button>
      </div>
    );
  }

  const submitLabel = desktopAccount ? "Authorize Desktop" : "Link Device";
  const submittingLabel = desktopAccount ? "Authorizing..." : "Linking...";

  // Authenticated — show code entry form
  return (
    <div className="bg-bg-white rounded-2xl border border-border-dim shadow-md p-8">
      <div className="text-sm text-text-secondary mb-6 text-center">
        Signed in as{" "}
        <span className="font-semibold text-ink">
          {(user as { email?: { address?: string } })?.email?.address || "your account"}
        </span>
      </div>

      <form onSubmit={handleSubmit} className="space-y-6">
        <div>
          <label
            htmlFor="device-code"
            className="block text-sm font-semibold text-ink mb-2"
          >
            {desktopAccount ? "Enter the code shown in the app" : "Enter the code shown in your terminal"}
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
          {status === "submitting" ? submittingLabel : submitLabel}
        </button>
      </form>

      <div className="mt-6 text-xs text-text-tertiary text-center">
        {desktopAccount ? "This grants 30-day access to view your Macs and earnings. It cannot start providers, manage API keys, or withdraw funds." : <>
          Run{" "}
          <code className="bg-bg-tertiary px-1.5 py-0.5 rounded font-mono text-coral border border-border-dim">
            darkbloom login
          </code>{" "}
          on your Mac to get a code.
        </>}
      </div>
    </div>
  );
}
