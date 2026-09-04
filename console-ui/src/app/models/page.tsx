"use client";

import { TopBar } from "@/components/TopBar";
import { ModelCatalog } from "@/components/models/ModelCatalog";

export default function ModelsPage() {
  return (
    <div className="flex h-full flex-col">
      <TopBar title="Models" />
      <div className="min-h-0 flex-1 overflow-y-auto">
        <ModelCatalog />
      </div>
    </div>
  );
}
