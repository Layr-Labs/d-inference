"use client";

import { trackEvent } from "@/lib/google-analytics";
import { GithubIcon, SlackIcon } from "./BrandIcons";
import { GITHUB_REPO_URL, SLACK_INVITE_URL } from "./constants";

export function CommunityLinks() {
  return (
    <div className="flex items-center gap-1 border-t border-border-dim px-3 py-2">
      <p className="flex-1 font-mono text-[8px] uppercase tracking-[0.14em] text-text-tertiary">Community</p>
      <a
        href={GITHUB_REPO_URL}
        target="_blank"
        rel="noopener noreferrer"
        onClick={() => trackEvent("community_github_clicked")}
        title="Darkbloom on GitHub"
        aria-label="Darkbloom on GitHub"
        className="rounded-lg p-1.5 text-text-tertiary transition-colors hover:bg-bg-hover hover:text-text-primary"
      >
        <GithubIcon size={14} />
      </a>
      <a
        href={SLACK_INVITE_URL}
        target="_blank"
        rel="noopener noreferrer"
        onClick={() => trackEvent("community_slack_clicked")}
        title="Join the Darkbloom Slack"
        aria-label="Join the Darkbloom Slack"
        className="rounded-lg p-1.5 text-text-tertiary transition-colors hover:bg-bg-hover hover:text-text-primary"
      >
        <SlackIcon size={14} />
      </a>
    </div>
  );
}
