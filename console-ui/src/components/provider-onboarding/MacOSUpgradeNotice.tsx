import { AlertTriangle } from "lucide-react";
import type { MyProvider } from "@/app/providers/types";
import { needsMacOSUpgrade, reportedMacOSMajor } from "@/app/providers/macos-upgrade";

export function MacOSUpgradeNotice({ providers }: { providers?: MyProvider[] }) {
  const older = providers?.filter(needsMacOSUpgrade).length ?? 0;
  const unknown = providers?.filter((p) => reportedMacOSMajor(p) === null).length ?? 0;
  if (providers && older === 0 && unknown === 0) return null;

  const title = !providers
    ? "Upgrade to macOS 27 for setup without MDM"
    : older > 0
      ? `Upgrade ${older === 1 ? "your Mac" : `${older} Macs`} to macOS 27`
      : "Check your Macs’ macOS versions";

  return (
    <aside aria-label="macOS upgrade notice" className="flex items-start gap-3 rounded-xl border border-accent-amber/30 bg-accent-amber/10 p-4">
      <AlertTriangle size={18} aria-hidden className="mt-0.5 shrink-0 text-accent-amber" />
      <div className="space-y-2 text-sm leading-relaxed text-text-secondary">
        <h2 className="font-medium text-text-primary">{title}</h2>
        <p>Darkbloom MDM will be deactivated soon. Upgrade to macOS 27 or later to use App Attest without Darkbloom MDM.</p>
        <p>Existing machines can continue through legacy verification during the transition. Keep your Darkbloom profile installed until <code>darkbloom unenroll</code> confirms App Attest migration is ready. Keep employer management profiles in place.</p>
        {providers && <p className="text-xs">Version notices use each Mac’s last reported version. After upgrading, restart the provider to refresh it.{unknown > 0 ? ` We don’t have a macOS version for ${unknown} ${unknown === 1 ? "machine" : "machines"}; check Apple menu → About This Mac.` : ""}</p>}
      </div>
    </aside>
  );
}
