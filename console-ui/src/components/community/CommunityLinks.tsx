"use client";

import { trackEvent } from "@/lib/google-analytics";
import { GithubIcon, SlackIcon } from "./BrandIcons";
import { GITHUB_REPO_URL, SLACK_INVITE_URL } from "./constants";

// Sidebar footer row: GitHub + Slack links for staying up to date on the project.
export function CommunityLinks() {
  return (
    <div className="px-4 py-2 border-t border-border-dim flex items-center gap-1">
      <p className="flex-1 text-[10px] text-text-tertiary">Follow along</p>
      <a
        href={GITHUB_REPO_URL}
        target="_blank"
        rel="noopener noreferrer"
        onClick={() => trackEvent("community_github_clicked")}
        title="Darkbloom on GitHub"
        aria-label="Darkbloom on GitHub"
        className="p-1.5 rounded-lg hover:bg-bg-hover text-text-tertiary hover:text-text-primary transition-colors"
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
        className="p-1.5 rounded-lg hover:bg-bg-hover text-text-tertiary hover:text-text-primary transition-colors"
      >
        <SlackIcon size={14} />
      </a>
    </div>
  );
}
