"use client";

import Link from "next/link";
import { AlertCircle, Check, ExternalLink, Loader2, ShieldCheck } from "lucide-react";
import { TopBar } from "@/components/TopBar";
import { PUBLIC_COORDINATOR_URL } from "@/lib/coordinator-url";
import { AppearanceSettings } from "./AppearanceSettings";
import { SettingsSection } from "./SettingsSection";
import { useConsoleSettings } from "./useConsoleSettings";

export default function SettingsPage() {
  const settings = useConsoleSettings();

  return (
    <div className="flex h-full flex-col">
      <TopBar title="Settings" />
      <div className="flex-1 overflow-y-auto">
        <div className="mx-auto max-w-5xl px-5 py-8 sm:px-10 sm:py-12">
          <div className="mb-10">
            <h1 className="font-logo text-4xl font-normal tracking-tight text-text-primary sm:text-5xl">Your workspace</h1>
            <p className="mt-3 max-w-xl text-sm leading-relaxed text-text-secondary">
              Appearance, request privacy, and connection preferences for this browser.
            </p>
          </div>

          <div className="divide-y divide-border-dim border-y border-border-dim">
            <SettingsSection title="Appearance" description="Choose how Darkbloom looks on this device.">
              <AppearanceSettings />
            </SettingsSection>

            <SettingsSection title="Request privacy" description="Add browser-side encryption before requests reach the coordinator.">
              <div className="flex items-start justify-between gap-5">
                <div>
                  <label htmlFor="request-encryption" className="block text-sm font-medium text-text-primary">Encrypt requests to coordinator</label>
                  <p id="encryption-description" className="mt-2 max-w-md text-sm leading-relaxed text-text-secondary">
                    Seal prompts with the coordinator&apos;s public key before they leave this browser. This optional setting takes effect immediately.
                  </p>
                </div>
                <button
                  id="request-encryption"
                  type="button"
                  role="switch"
                  aria-checked={settings.encryptToCoord}
                  aria-describedby="encryption-description"
                  aria-label="Encrypt requests to coordinator"
                  disabled={settings.encStatus === "checking"}
                  onClick={() => settings.handleEncryptionToggle(!settings.encryptToCoord)}
                  className={`relative mt-0.5 h-7 w-12 shrink-0 rounded-full transition-colors disabled:cursor-wait ${settings.encryptToCoord ? "bg-accent-brand" : "bg-border-subtle"}`}
                >
                  <span className={`absolute left-1 top-1 h-5 w-5 rounded-full bg-white shadow-sm transition-transform ${settings.encryptToCoord ? "translate-x-5" : ""}`} />
                </button>
              </div>
              <div aria-live="polite" className="mt-4 text-sm">
                {settings.encStatus === "idle" && <p className="text-text-secondary">{settings.encryptToCoord ? "Enabled for this browser." : "Off by default. Turn on to check coordinator support."}</p>}
                {settings.encStatus === "checking" && <p className="flex items-center gap-2 text-text-secondary"><Loader2 size={15} className="animate-spin" />Checking encryption support…</p>}
                {settings.encStatus === "ok" && <p className="flex items-center gap-2 text-accent-green"><ShieldCheck size={16} />Encryption ready</p>}
                {(settings.encStatus === "error" || settings.encStatus === "unavailable") && (
                  <div className="rounded-lg bg-accent-red/5 px-4 py-3">
                    <p className="flex items-start gap-2 text-accent-red"><AlertCircle size={16} className="mt-0.5 shrink-0" />{settings.encInfo}</p>
                    <p className="mt-2 text-xs leading-relaxed text-text-secondary">Requests will fail while encryption is enabled and a key is unavailable. Retry the check or turn this setting off.</p>
                    <button type="button" onClick={() => settings.handleEncryptionToggle(true)} className="mt-3 text-sm font-medium text-accent-brand hover:underline">Check again</button>
                  </div>
                )}
              </div>
              <details className="group mt-4 text-sm text-text-secondary">
                <summary className="w-fit cursor-pointer text-xs font-medium hover:text-text-primary">How request encryption works</summary>
                <p className="mt-3 max-w-lg text-xs leading-relaxed">The browser seals each request using X25519 and NaCl Box. The coordinator decrypts the request and re-seals it for the selected provider. Network intermediaries receive encrypted request bodies.</p>
                {settings.encStatus === "ok" && <p className="mt-2 break-all font-mono text-xs">Key ID: {settings.encInfo}</p>}
              </details>
            </SettingsSection>

            <SettingsSection title="API configuration" description="Set the base URL used in your integration examples.">
              <form onSubmit={(event) => { event.preventDefault(); settings.handleSave(); }}>
                <label htmlFor="coordinator-url" className="mb-2 block text-sm font-medium text-text-primary">API example URL</label>
                <input
                  id="coordinator-url"
                  type="url"
                  required
                  value={settings.exampleUrl}
                  onChange={(event) => settings.updateExampleUrl(event.target.value)}
                  placeholder={PUBLIC_COORDINATOR_URL}
                  aria-describedby="coordinator-url-hint"
                  className="w-full rounded-lg border border-border-subtle bg-bg-white px-3.5 py-3 font-mono text-sm text-text-primary outline-none transition-colors focus:border-accent-brand focus:ring-2 focus:ring-accent-brand/10"
                />
                <p id="coordinator-url-hint" className="mt-2 text-xs leading-relaxed text-text-secondary">Used by the API console&apos;s code examples. The console&apos;s own connection is configured separately by its operator.</p>
                <div className="mt-4 flex flex-wrap items-center gap-3">
                  <button type="submit" disabled={!settings.hasChanges} className="inline-flex min-h-10 items-center justify-center gap-2 rounded-lg bg-accent-brand px-4 text-sm font-medium text-white dark:text-bg-primary transition-opacity hover:opacity-90 disabled:cursor-default disabled:opacity-40">
                    {settings.saved ? <><Check size={15} />Saved</> : "Save URL"}
                  </button>
                  {settings.hasChanges && <span className="text-xs text-text-secondary">Unsaved changes</span>}
                  <Link href="/api-console" className="ml-auto inline-flex items-center gap-1.5 text-sm font-medium text-accent-brand hover:underline">API console<ExternalLink size={13} /></Link>
                </div>
              </form>
            </SettingsSection>

            <SettingsSection title="Console connection" description="Check the service this console is connected to.">
              <p className="break-all font-mono text-sm text-text-primary">{PUBLIC_COORDINATOR_URL}</p>
              <div className="mt-4 flex flex-wrap items-center gap-3">
                <button type="button" onClick={() => settings.handleHealthCheck()} disabled={settings.healthStatus === "checking"} className="inline-flex min-h-10 items-center gap-2 rounded-lg border border-border-subtle bg-bg-white px-4 text-sm font-medium text-text-primary transition-colors hover:bg-bg-hover disabled:opacity-50">
                  {settings.healthStatus === "checking" && <Loader2 size={15} className="animate-spin" />}
                  {settings.healthStatus === "checking" ? "Checking…" : "Test connection"}
                </button>
                <div aria-live="polite" className="min-w-0 text-sm">
                  {settings.healthStatus === "ok" && <span className="flex items-center gap-2 text-accent-green"><Check size={15} />{settings.healthInfo}</span>}
                  {settings.healthStatus === "error" && <span className="flex items-center gap-2 text-accent-red"><AlertCircle size={15} />{settings.healthInfo}</span>}
                </div>
              </div>
            </SettingsSection>
          </div>
          <p className="mt-6 text-xs leading-relaxed text-text-secondary">These preferences are saved on this device. They do not change settings on your other browsers.</p>
        </div>
      </div>
    </div>
  );
}
