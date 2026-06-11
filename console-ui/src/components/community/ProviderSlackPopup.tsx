"use client";

import { useCallback, useEffect, useState } from "react";
import { usePathname } from "next/navigation";
import { X } from "lucide-react";
import { trackEvent } from "@/lib/google-analytics";
import {
  INVITE_DISMISSED_EVENT,
  INVITE_DISMISSED_KEY,
} from "@/components/InviteCodeBanner";
import { SlackIcon } from "./BrandIcons";
import { PROVIDER_SLACK_DISMISSED_KEY, SLACK_INVITE_URL } from "./constants";
import { useIsConnectedProvider } from "./useIsConnectedProvider";

// The invite banner owns the bottom-right corner on the chat page; while it
// can still be visible there, this popup waits its turn.
function useInviteBannerOccupiesCorner(): boolean {
  const pathname = usePathname();
  const [inviteDismissed, setInviteDismissed] = useState(() => {
    if (typeof window === "undefined") return false;
    return localStorage.getItem(INVITE_DISMISSED_KEY) === "1";
  });

  useEffect(() => {
    const onDismissed = () => setInviteDismissed(true);
    window.addEventListener(INVITE_DISMISSED_EVENT, onDismissed);
    return () => window.removeEventListener(INVITE_DISMISSED_EVENT, onDismissed);
  }, []);

  return pathname === "/" && !inviteDismissed;
}

// Corner popup shown once to users with a connected provider machine,
// inviting them to the provider Slack channel. Dismissal persists in
// localStorage (same pattern as InviteCodeBanner).
export function ProviderSlackPopup() {
  const [dismissed, setDismissed] = useState(() => {
    if (typeof window === "undefined") return true;
    return localStorage.getItem(PROVIDER_SLACK_DISMISSED_KEY) === "1";
  });
  // Skip the providers fetch entirely once dismissed.
  const isProvider = useIsConnectedProvider(!dismissed);
  const cornerBusy = useInviteBannerOccupiesCorner();

  const dismiss = useCallback(() => {
    setDismissed(true);
    localStorage.setItem(PROVIDER_SLACK_DISMISSED_KEY, "1");
  }, []);

  const handleDismiss = useCallback(() => {
    trackEvent("provider_slack_popup_dismissed");
    dismiss();
  }, [dismiss]);

  const handleJoin = useCallback(() => {
    trackEvent("provider_slack_popup_joined");
    dismiss();
  }, [dismiss]);

  if (dismissed || !isProvider || cornerBusy) return null;

  return (
    <div className="fixed bottom-4 right-3 sm:right-6 z-40 w-[calc(100%-1.5rem)] sm:w-auto sm:max-w-sm message-animate">
      <div className="bg-bg-white border border-border-dim rounded-xl shadow-lg overflow-hidden">
        <div className="flex items-center justify-between px-4 py-3">
          <div className="flex items-center gap-2 text-sm font-semibold text-ink">
            <div className="w-7 h-7 rounded-lg bg-bg-elevated border-2 border-border-subtle flex items-center justify-center">
              <SlackIcon size={14} className="text-ink" />
            </div>
            You&apos;re a provider!
          </div>
          <button
            onClick={handleDismiss}
            className="p-1 rounded-lg hover:bg-bg-hover text-text-tertiary hover:text-text-primary transition-colors"
            aria-label="Dismiss"
          >
            <X size={14} />
          </button>
        </div>

        <div className="px-4 pb-2">
          <p className="text-xs text-text-tertiary leading-relaxed">
            We have a Slack channel just for providers. If you have any questions
            or want updates on the network, come say hi.
          </p>
        </div>

        <div className="px-4 pb-3">
          <a
            href={SLACK_INVITE_URL}
            target="_blank"
            rel="noopener noreferrer"
            onClick={handleJoin}
            className="block w-full py-2 rounded-lg bg-coral border-2 border-ink text-white text-center text-xs font-bold
                       hover:opacity-90 transition-all"
          >
            Join the provider channel
          </a>
        </div>
      </div>
    </div>
  );
}
