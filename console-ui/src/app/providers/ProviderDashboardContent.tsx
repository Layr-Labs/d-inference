"use client";

// Thin entry point kept so page.tsx's import stays stable. The dashboard lives
// in the modular providers/dashboard/ package.
import { ProviderDashboard } from "./dashboard";

export default function ProviderDashboardContent() {
  return <ProviderDashboard />;
}
