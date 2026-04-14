"use client";

export default function ImagesPage() {
  return (
    <div className="flex-1 flex flex-col h-full">
      <div className="border-b border-border-dim px-6 py-4">
        <div className="flex items-center gap-2">
          <h1 className="text-2xl font-semibold text-ink">Image Generation</h1>
          <span className="px-2 py-0.5 rounded-full bg-coral/10 border border-coral/30 text-coral text-[10px] font-bold uppercase tracking-wider">
            In Progress
          </span>
        </div>
        <p className="text-sm text-text-tertiary mt-0.5">
          Generate images with FLUX models running on attested Apple Silicon.
        </p>
      </div>

      <div className="flex-1 flex items-center justify-center">
        <div className="text-center max-w-md px-6">
          <div className="w-16 h-16 rounded-2xl bg-bg-secondary border border-border-dim flex items-center justify-center mx-auto mb-4">
            <svg width="28" height="28" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.5" className="text-text-tertiary">
              <rect x="3" y="3" width="18" height="18" rx="2" />
              <circle cx="8.5" cy="8.5" r="1.5" />
              <path d="m21 15-3.086-3.086a2 2 0 0 0-2.828 0L6 21" />
            </svg>
          </div>
          <h3 className="text-lg font-semibold text-text-primary mb-2">Image generation is in progress</h3>
          <p className="text-sm text-text-tertiary">
            We are actively onboarding image providers to the network. This feature will be available soon with FLUX models running on hardware-attested Apple Silicon.
          </p>
        </div>
      </div>
    </div>
  );
}
