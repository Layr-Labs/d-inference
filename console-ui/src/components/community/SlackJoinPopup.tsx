"use client";

import { useCallback, useEffect, useState } from "react";
import { usePathname } from "next/navigation";
import { X } from "lucide-react";
import { trackEvent } from "@/lib/google-analytics";
import {
  INVITE_DISMISSED_EVENT,
  INVITE_DISMISSED_KEY,
} from "@/components/InviteCodeBanner";
import { useAuth } from "@/hooks/useAuth";
import { SlackIcon } from "./BrandIcons";
import { SLACK_INVITE_URL, SLACK_JOIN_DISMISSED_KEY } from "./constants";

// The invite banner owns the bottom-right corner on the chat page; while it
// can still be visible there, this popup waits its turn.
function useInviteBannerOccupiesCorner(): boolean {
  const pathname = usePathname();
  const [inviteDismissed, setInviteDismissed] = useState(false);

  useEffect(() => {
    setInviteDismissed(localStorage.getItem(INVITE_DISMISSED_KEY) === "1");
    const onDismissed = () => setInviteDismissed(true);
    window.addEventListener(INVITE_DISMISSED_EVENT, onDismissed);
    return () => window.removeEventListener(INVITE_DISMISSED_EVENT, onDismissed);
  }, []);

  return pathname === "/" && !inviteDismissed;
}

// One-time corner popup for signed-in users, pointing them at Slack.
// Dismissal persists in localStorage (same pattern as InviteCodeBanner).
export function SlackJoinPopup() {
  const { authenticated } = useAuth();
  const [dismissed, setDismissed] = useState(true);
  const cornerBusy = useInviteBannerOccupiesCorner();

  useEffect(() => {
    setDismissed(localStorage.getItem(SLACK_JOIN_DISMISSED_KEY) === "1");
  }, []);

  const dismiss = useCallback(() => {
    setDismissed(true);
    localStorage.setItem(SLACK_JOIN_DISMISSED_KEY, "1");
  }, []);

  const handleDismiss = useCallback(() => {
    trackEvent("slack_join_popup_dismissed");
    dismiss();
  }, [dismiss]);

  const handleJoin = useCallback(() => {
    trackEvent("slack_join_popup_joined");
    dismiss();
  }, [dismiss]);

  if (!authenticated || dismissed || cornerBusy) return null;

  return (
    <div className="fixed bottom-4 right-3 sm:right-6 z-40 w-[calc(100%-1.5rem)] sm:w-auto sm:max-w-sm message-animate">
      <div className="bg-bg-white border border-border-dim rounded-xl shadow-lg overflow-hidden">
        <div className="flex items-center justify-between px-4 py-3">
          <div className="flex items-center gap-2 text-sm font-semibold text-ink">
            <div className="w-7 h-7 rounded-lg bg-bg-elevated border-2 border-border-subtle flex items-center justify-center">
              <SlackIcon size={14} className="text-ink" />
            </div>
            Join the Darkbloom Slack
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
            You&apos;re already on Darkbloom — come join Slack for updates,
            support, and conversation with other users and providers.
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
            Join Slack
          </a>
        </div>
      </div>
    </div>
  );
}
