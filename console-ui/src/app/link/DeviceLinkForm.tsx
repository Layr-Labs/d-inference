"use client";

import { useState, useCallback } from "react";
import { useAuthContext } from "@/components/providers/PrivyClientProvider";

const COORDINATOR_URL =
  process.env.NEXT_PUBLIC_COORDINATOR_URL ||
  "https://inference-test.openinnovation.dev";

type LinkStatus = "idle" | "submitting" | "success" | "error";

export function DeviceLinkForm() {
  const { ready, authenticated, login, getAccessToken, user } = useAuthContext();
  const [code, setCode] = useState("");
  const [status, setStatus] = useState<LinkStatus>("idle");
  const [errorMsg, setErrorMsg] = useState("");

  const handleSubmit = useCallback(
    async (e: React.FormEvent) => {
      e.preventDefault();
      if (!code.trim()) return;

      setStatus("submitting");
      setErrorMsg("");

      try {
        const token = await getAccessToken();
        if (!token) {
          setErrorMsg("Failed to get auth token. Please log in again.");
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
          setErrorMsg(
            data?.error?.message || data?.message || "Failed to link device"
          );
          setStatus("error");
          return;
        }

        setStatus("success");
      } catch {
        setErrorMsg("Network error. Please check your connection.");
        setStatus("error");
      }
    },
    [code, getAccessToken]
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
      <div className="bg-white rounded-2xl shadow-lg border border-slate-200 p-8 text-center">
        <div className="animate-pulse text-slate-400">Loading...</div>
      </div>
    );
  }

  // Success state
  if (status === "success") {
    return (
      <div className="bg-white rounded-2xl shadow-lg border border-slate-200 p-8 text-center">
        <div className="w-16 h-16 bg-green-100 rounded-full flex items-center justify-center mx-auto mb-4">
          <svg
            className="w-8 h-8 text-green-600"
            fill="none"
            viewBox="0 0 24 24"
            stroke="currentColor"
          >
            <path
              strokeLinecap="round"
              strokeLinejoin="round"
              strokeWidth={2}
              d="M5 13l4 4L19 7"
            />
          </svg>
        </div>
        <h2 className="text-xl font-semibold text-slate-900 mb-2">
          Device Linked!
        </h2>
        <p className="text-slate-500">
          Your provider is now connected to your account. Earnings will be
          credited automatically.
        </p>
        <p className="text-slate-400 text-sm mt-4">
          You can close this page.
        </p>
      </div>
    );
  }

  // Not authenticated — show login prompt
  if (!authenticated) {
    return (
      <div className="bg-white rounded-2xl shadow-lg border border-slate-200 p-8 text-center">
        <p className="text-slate-600 mb-6">
          Sign in to your EigenInference account to link your device.
        </p>
        <button
          onClick={login}
          className="w-full px-6 py-3 bg-indigo-600 text-white rounded-xl font-medium hover:bg-indigo-700 transition-colors"
        >
          Sign In
        </button>
      </div>
    );
  }

  // Authenticated — show code entry form
  return (
    <div className="bg-white rounded-2xl shadow-lg border border-slate-200 p-8">
      <div className="text-sm text-slate-500 mb-6 text-center">
        Signed in as{" "}
        <span className="font-medium text-slate-700">
          {(user as { email?: { address?: string }; wallet?: { address?: string } })?.email?.address ||
            (user as { wallet?: { address?: string } })?.wallet?.address ||
            "your account"}
        </span>
      </div>

      <form onSubmit={handleSubmit} className="space-y-6">
        <div>
          <label
            htmlFor="device-code"
            className="block text-sm font-medium text-slate-700 mb-2"
          >
            Enter the code shown in your terminal
          </label>
          <input
            id="device-code"
            type="text"
            value={code}
            onChange={(e) => handleCodeChange(e.target.value)}
            placeholder="XXXX-XXXX"
            maxLength={9}
            className="w-full px-4 py-3 text-center text-2xl font-mono tracking-widest border border-slate-300 rounded-xl focus:ring-2 focus:ring-indigo-500 focus:border-indigo-500 outline-none"
            autoFocus
            autoComplete="off"
          />
        </div>

        {status === "error" && (
          <div className="text-red-600 text-sm bg-red-50 rounded-lg p-3">
            {errorMsg}
          </div>
        )}

        <button
          type="submit"
          disabled={code.replace("-", "").length !== 8 || status === "submitting"}
          className="w-full px-6 py-3 bg-indigo-600 text-white rounded-xl font-medium hover:bg-indigo-700 transition-colors disabled:opacity-50 disabled:cursor-not-allowed"
        >
          {status === "submitting" ? "Linking..." : "Link Device"}
        </button>
      </form>

      <div className="mt-6 text-xs text-slate-400 text-center">
        Run{" "}
        <code className="bg-slate-100 px-1.5 py-0.5 rounded font-mono">
          dginf-provider login
        </code>{" "}
        on your Mac to get a code.
      </div>
    </div>
  );
}
