"use client";

import { TopBar } from "@/components/TopBar";
import { usePathname } from "next/navigation";

export default function ProvidersLayout({ children }: { children: React.ReactNode }) {
  const pathname = usePathname();
  const titles: Record<string, string> = { "/providers/setup": "Provider setup", "/providers/earnings": "Your earnings" };
  const title = titles[pathname] ?? "Your fleet";
  return <div className="flex h-full min-h-0 flex-col"><TopBar title={title} /><div className="min-h-0 flex-1 overflow-y-auto">{children}</div></div>;
}
