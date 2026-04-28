"use client";

import dynamic from "next/dynamic";
import { Loader2 } from "lucide-react";

const BillingContent = dynamic(() => import("@/app/billing/BillingContent"), {
  ssr: false,
  loading: () => (
    <div className="flex items-center justify-center h-64">
      <Loader2 size={24} className="animate-spin text-accent-brand" />
    </div>
  ),
});

export default function BillingPage() {
  return <BillingContent />;
}
