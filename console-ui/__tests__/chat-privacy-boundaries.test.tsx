import { render, screen } from "@testing-library/react";
import { describe, expect, it } from "vitest";
import { privacySafeRumConfig } from "@/components/DatadogRUM";
import { ChatMessage } from "@/components/chat/ChatMessage";
import { UserMessage } from "@/components/chat/UserMessage";

const SENTINEL = "PRIVATE_CHAT_SENTINEL";

describe("chat observability privacy boundaries", () => {
  it("disables replay and masks all DOM text by default", () => {
    const config = privacySafeRumConfig("app", "token", "datadoghq.com");
    expect(config.sessionReplaySampleRate).toBe(0);
    expect(config.defaultPrivacyLevel).toBe("mask");
    expect(config.startSessionReplayRecordingManually).toBe(true);
    expect(config.enablePrivacyForActionName).toBe(true);
  });

  it("marks rendered prompts and decrypted responses as masked", () => {
    const { unmount } = render(<UserMessage message={{
      id: "user-1",
      role: "user",
      content: SENTINEL,
      timestamp: 1,
    }} />);
    expect(screen.getByText(SENTINEL).closest("[data-dd-privacy='mask']")).not.toBeNull();
    unmount();

    render(<ChatMessage message={{
      id: "assistant-1",
      role: "assistant",
      content: SENTINEL,
      timestamp: 2,
    }} />);
    expect(screen.getByText(SENTINEL).closest("[data-dd-privacy='mask']")).not.toBeNull();
  });

  it("surfaces a coordinator-forced strict self route on the completed response", () => {
    render(<ChatMessage message={{
      id: "assistant-self",
      role: "assistant",
      content: "done",
      timestamp: 3,
      trust: {
        attested: true,
        trustLevel: "hardware",
        secureEnclave: true,
        mdaVerified: true,
        providerChip: "",
        providerModel: "org/concrete-model",
        privacyTier: "private-v2-process-bound",
        routeMode: "self_route_only",
      },
    }} />);
    expect(screen.getByText(/Self only/u)).toBeInTheDocument();
  });
});
