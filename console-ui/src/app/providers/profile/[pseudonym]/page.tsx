"use client";

import { useEffect, useState } from "react";
import { useParams } from "next/navigation";
import { Loader2 } from "lucide-react";
import { PublicProviderProfileCard } from "@/components/providers/PublicProviderProfile";
import type { PublicProviderProfile } from "@/components/leaderboard/types";

export default function ProviderProfilePage() {
  const params = useParams<{ pseudonym: string }>();
  const pseudonym = params?.pseudonym ?? "";

  const [profile, setProfile] = useState<PublicProviderProfile | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    if (!pseudonym) return;
    setLoading(true);
    setError(null);

    const load = async () => {
      try {
        const res = await fetch(`/api/providers/profile/${encodeURIComponent(pseudonym)}`);
        if (!res.ok) {
          const body = await res.json().catch(() => ({})) as { error?: string };
          throw new Error(body.error ?? `Request failed (${res.status})`);
        }
        setProfile(await res.json() as PublicProviderProfile);
      } catch (err) {
        setError(err instanceof Error ? err.message : "Unknown error");
      } finally {
        setLoading(false);
      }
    };

    return void load();
  }, [pseudonym]);

  if (loading) {
    return (
      <div className="flex min-h-[40vh] items-center justify-center">
        <Loader2 className="animate-spin text-text-tertiary" size={24} />
      </div>
    );
  }

  if (error || !profile) {
    return (
      <div className="mx-auto max-w-2xl px-4 py-12 text-center">
        <p className="font-mono text-text-secondary">
          {error?.includes("404") || error?.includes("not found")
            ? "Provider not found or currently offline."
            : (error ?? "Failed to load provider profile.")}
        </p>
        <p className="mt-1 text-xs font-mono text-text-tertiary">{pseudonym}</p>
      </div>
    );
  }

  return <PublicProviderProfileCard profile={profile} />;
}
