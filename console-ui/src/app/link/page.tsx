"use client";

import { DeviceLinkForm } from "./DeviceLinkForm";

export default function LinkPage() {
  return (
    <div className="min-h-screen bg-bg-primary flex items-center justify-center p-4">
      <div className="w-full max-w-md">
        {/* Icon */}
        <div className="mb-6 text-center">
          <svg width="72" height="72" viewBox="0 0 64 64" fill="none" className="mx-auto">
            <circle cx="32" cy="32" r="28" fill="var(--coral-light)" stroke="var(--ink)" strokeWidth="3"/>
            <rect x="18" y="22" width="28" height="18" rx="3" fill="var(--bg-white)" stroke="var(--ink)" strokeWidth="2.5"/>
            <rect x="22" y="25" width="20" height="11" rx="1.5" fill="var(--teal-light)" stroke="var(--ink)" strokeWidth="1.5"/>
            <path d="M26 36 Q28 39, 32 39.5 Q36 39, 38 36" stroke="var(--ink)" strokeWidth="2" fill="var(--bg-white)"/>
            <circle cx="32" cy="37" r="1.5" fill="var(--ink)"/>
          </svg>
        </div>

        <div className="text-center mb-8">
          <h1 className="text-3xl font-semibold text-ink">
            Link Your Device
          </h1>
          <p className="text-text-secondary mt-2">
            Connect your Mac to your Darkbloom account to receive
            earnings for providing compute.
          </p>
        </div>
        <DeviceLinkForm />
      </div>
    </div>
  );
}
