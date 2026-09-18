"use client";

import { useConsoleExperience } from "@/components/console-entry/ConsoleExperience";
import { ProviderOnboarding } from "@/components/provider-onboarding/ProviderOnboarding";

export default function ProviderSetupPage() {
  const { providerAccount } = useConsoleExperience();

  return (
    <ProviderOnboarding hasLinkedProviders={providerAccount.status === "linked"} />
  );
}
