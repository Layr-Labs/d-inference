"use client";

import { useState, useEffect, useCallback } from "react";
import { TopBar } from "@/components/TopBar";
import { useToastStore } from "@/hooks/useToast";
import { usePathname } from "@/i18n/navigation";
import {
  localeCookieName,
  localeLabels,
  locales,
  type Locale,
} from "@/i18n/locales";
import {
  getGoogleAnalyticsConsentStorageKey,
  getGoogleAnalyticsConsentStatus,
  grantGoogleAnalyticsConsent,
  revokeGoogleAnalyticsConsent,
} from "@/lib/google-analytics";
import {
  Globe,
  Check,
  AlertCircle,
  Loader2,
  Server,
  Lock,
  BarChart3,
  Languages,
} from "lucide-react";
import { useLocale, useTranslations } from "next-intl";
import { healthCheck } from "@/lib/api";
import {
  clearCoordinatorKeyCache,
  getCoordinatorKey,
  isEncryptionEnabled,
  setEncryptionEnabled,
} from "@/lib/encryption";

export default function SettingsPage() {
  const addToast = useToastStore((s) => s.addToast);
  const t = useTranslations("SettingsPage");
  const currentLocale = useLocale() as Locale;
  const pathname = usePathname();
  const [coordinatorUrl, setCoordinatorUrl] = useState("");
  const [analyticsConsent, setAnalyticsConsent] = useState<
    "granted" | "denied" | "unset"
  >("unset");
  const [saved, setSaved] = useState(false);
  const [healthStatus, setHealthStatus] = useState<
    "idle" | "checking" | "ok" | "error"
  >("idle");
  const [healthInfo, setHealthInfo] = useState("");

  const [encryptToCoord, setEncryptToCoord] = useState(false);
  const [encStatus, setEncStatus] = useState<
    "idle" | "checking" | "ok" | "unavailable" | "error"
  >("idle");
  const [encInfo, setEncInfo] = useState("");

  const syncAnalyticsConsent = useCallback(() => {
    setAnalyticsConsent(getGoogleAnalyticsConsentStatus());
  }, []);

  useEffect(() => {
    if (typeof window !== "undefined") {
      setCoordinatorUrl(
        localStorage.getItem("darkbloom_coordinator_url") ||
          process.env.NEXT_PUBLIC_COORDINATOR_URL ||
          "https://api.darkbloom.dev"
      );
      setEncryptToCoord(isEncryptionEnabled());
      syncAnalyticsConsent();
    }
  }, [syncAnalyticsConsent]);

  useEffect(() => {
    window.addEventListener("darkbloom-ga-consent-changed", syncAnalyticsConsent);
    const handleStorage = (event: StorageEvent) => {
      if (event.key === getGoogleAnalyticsConsentStorageKey()) {
        syncAnalyticsConsent();
      }
    };
    window.addEventListener("storage", handleStorage);
    return () =>
      {
        window.removeEventListener(
          "darkbloom-ga-consent-changed",
          syncAnalyticsConsent
        );
        window.removeEventListener("storage", handleStorage);
      };
  }, [syncAnalyticsConsent]);

  // When the user flips the toggle, eagerly fetch the coordinator pubkey so
  // they get an immediate signal if the feature is unavailable on this
  // coordinator (rather than failing on first message send).
  const handleEncryptionToggle = async (enabled: boolean) => {
    setEncryptToCoord(enabled);
    setEncryptionEnabled(enabled);
    if (!enabled) {
      setEncStatus("idle");
      setEncInfo("");
      clearCoordinatorKeyCache();
      addToast(t("encryption.disabledToast"), "success");
      return;
    }
    setEncStatus("checking");
    try {
      const k = await getCoordinatorKey(true);
      setEncStatus("ok");
      setEncInfo(t("encryption.keyInfo", { kid: k.kid }));
      addToast(t("encryption.enabledToast"), "success");
    } catch (err) {
      const msg = err instanceof Error ? err.message : String(err);
      if (msg.includes("not configured")) {
        setEncStatus("unavailable");
      } else {
        setEncStatus("error");
      }
      setEncInfo(msg);
      // Stay enabled so the user knows they intended this — but every request
      // will surface a clear error until the coordinator publishes a key.
    }
  };

  const handleSave = () => {
    localStorage.setItem("darkbloom_coordinator_url", coordinatorUrl);
    setSaved(true);
    addToast(t("savedToast"), "success");
    setTimeout(() => setSaved(false), 2000);
  };

  const handleLocaleChange = (nextLocale: Locale) => {
    document.cookie = `${localeCookieName}=${nextLocale}; Path=/; Max-Age=31536000; SameSite=Lax`;
    const nextPath =
      nextLocale === "en"
        ? pathname
        : `/${nextLocale}${pathname === "/" ? "" : pathname}`;
    window.location.assign(`${nextPath}${window.location.search}`);
  };

  const handleHealthCheck = async () => {
    setHealthStatus("checking");
    try {
      const result = await healthCheck();
      setHealthStatus("ok");
      setHealthInfo(t("coordinator.connected", { count: result.providers ?? 0 }));
    } catch (err) {
      setHealthStatus("error");
      setHealthInfo((err as Error).message);
    }
  };

  return (
    <div className="flex flex-col h-full">
      <TopBar title={t("title")} />

      <div className="flex-1 overflow-y-auto">
        <div className="max-w-2xl mx-auto px-3 sm:px-6 py-6 sm:py-8 space-y-8">
          {/* Coordinator URL */}
          <section className="rounded-xl bg-bg-white border border-border-dim p-6 shadow-md">
            <div className="flex items-center gap-2 mb-4">
              <Globe size={14} className="text-accent-green" />
              <h3 className="text-sm font-medium text-text-primary">
                {t("coordinator.title")}
              </h3>
            </div>
            <p className="text-xs text-text-tertiary mb-4">
              {t("coordinator.description")}
            </p>
            <input
              type="text"
              value={coordinatorUrl}
              onChange={(e) => setCoordinatorUrl(e.target.value)}
              placeholder="https://coordinator.darkbloom.io"
              className="w-full bg-bg-tertiary border border-border-subtle rounded-lg px-4 py-3 text-text-primary font-mono text-sm outline-none focus:border-accent-green/50 transition-colors"
            />

            {/* Health check */}
            <div className="flex items-center gap-3 mt-4">
              <button
                onClick={handleHealthCheck}
                disabled={healthStatus === "checking"}
                className="flex items-center gap-2 px-3 py-1.5 rounded-lg bg-bg-tertiary border border-border-subtle text-text-secondary text-xs font-mono hover:bg-bg-hover transition-colors disabled:opacity-50"
              >
                {healthStatus === "checking" ? (
                  <Loader2 size={12} className="animate-spin" />
                ) : (
                  <Server size={12} />
                )}
                {t("coordinator.test")}
              </button>
              {healthStatus === "ok" && (
                <span className="flex items-center gap-1 text-xs text-accent-green font-mono">
                  <Check size={12} />
                  {healthInfo}
                </span>
              )}
              {healthStatus === "error" && (
                <span className="flex items-center gap-1 text-xs text-accent-red font-mono">
                  <AlertCircle size={12} />
                  {healthInfo}
                </span>
              )}
            </div>
          </section>

          {/* Language */}
          <section className="rounded-xl bg-bg-white border border-border-dim p-6 shadow-md">
            <div className="flex items-center gap-2 mb-4">
              <Languages size={14} className="text-accent-green" />
              <h3 className="text-sm font-medium text-text-primary">
                {t("language.title")}
              </h3>
            </div>
            <p className="text-xs text-text-tertiary mb-4">
              {t("language.description")}
            </p>
            <select
              value={currentLocale}
              onChange={(e) => handleLocaleChange(e.target.value as Locale)}
              className="w-full bg-bg-tertiary border border-border-subtle rounded-lg px-4 py-3 text-text-primary text-sm outline-none focus:border-accent-green/50 transition-colors"
            >
              {locales.map((locale) => (
                <option key={locale} value={locale}>
                  {localeLabels[locale]}
                </option>
              ))}
            </select>
            <p className="mt-3 text-xs text-text-tertiary">
              {t("language.detected", { locale: localeLabels[currentLocale] })}
            </p>
          </section>

          {/* Sender → Coordinator encryption */}
          <section className="rounded-xl bg-bg-white border border-border-dim p-6 shadow-md">
            <div className="flex items-center gap-2 mb-4">
              <Lock size={14} className="text-accent-green" />
              <h3 className="text-sm font-medium text-text-primary">
                {t("encryption.title")}
              </h3>
            </div>
            <p className="text-xs text-text-tertiary mb-4">
              {t("encryption.description")}
            </p>
            <label className="flex items-center gap-3 text-sm text-text-primary cursor-pointer">
              <input
                type="checkbox"
                checked={encryptToCoord}
                onChange={(e) => handleEncryptionToggle(e.target.checked)}
                className="w-4 h-4 accent-coral"
              />
              <span>{t("encryption.checkbox")}</span>
            </label>
            <div className="flex items-center gap-3 mt-4 text-xs font-mono">
              {encStatus === "checking" && (
                <span className="flex items-center gap-1 text-text-tertiary">
                  <Loader2 size={12} className="animate-spin" />
                  {t("encryption.fetching")}
                </span>
              )}
              {encStatus === "ok" && (
                <span className="flex items-center gap-1 text-accent-green">
                  <Check size={12} />
                  {encInfo}
                </span>
              )}
              {encStatus === "unavailable" && (
                <span className="flex items-center gap-1 text-accent-red">
                  <AlertCircle size={12} />
                  {t("encryption.unavailable")}
                </span>
              )}
              {encStatus === "error" && (
                <span className="flex items-center gap-1 text-accent-red">
                  <AlertCircle size={12} />
                  {encInfo}
                </span>
              )}
            </div>
          </section>

          {/* Analytics */}
          <section className="rounded-xl bg-bg-white border border-border-dim p-6 shadow-md">
            <div className="flex items-center gap-2 mb-4">
              <BarChart3 size={14} className="text-accent-green" />
              <h3 className="text-sm font-medium text-text-primary">
                {t("analytics.title")}
              </h3>
            </div>
            <p className="text-xs text-text-tertiary mb-4">
              {t("analytics.description")}
            </p>
            <div className="flex flex-wrap gap-3">
              <button
                onClick={() => {
                  grantGoogleAnalyticsConsent();
                  addToast(t("analytics.enabledToast"), "success");
                }}
                className={`rounded-lg px-4 py-2 text-sm font-semibold transition-all ${
                  analyticsConsent === "granted"
                    ? "bg-coral text-white"
                    : "border border-border-dim text-text-secondary hover:bg-bg-hover"
                }`}
              >
                {t("analytics.allow")}
              </button>
              <button
                onClick={() => {
                  revokeGoogleAnalyticsConsent();
                  addToast(t("analytics.disabledToast"), "success");
                }}
                className={`rounded-lg px-4 py-2 text-sm font-semibold transition-all ${
                  analyticsConsent === "denied"
                    ? "bg-bg-tertiary text-text-primary"
                    : "border border-border-dim text-text-secondary hover:bg-bg-hover"
                }`}
              >
                {t("analytics.decline")}
              </button>
            </div>
            <p className="mt-3 text-xs text-text-tertiary">
              {t("analytics.current")}{" "}
              <span className="font-mono text-text-secondary uppercase">
                {analyticsConsent}
              </span>
            </p>
          </section>

          {/* Save */}
          <button
            onClick={handleSave}
            className="w-full py-3 rounded-lg bg-coral text-white font-bold text-sm border border-border-dim hover:opacity-90 transition-all flex items-center justify-center gap-2"
          >
            {saved ? (
              <>
                <Check size={14} />
                {t("saved")}
              </>
            ) : (
              t("save")
            )}
          </button>

          {/* Info */}
          <div className="rounded-xl bg-bg-white border border-border-dim p-5 shadow-md">
            <h4 className="text-xs font-mono text-text-tertiary uppercase tracking-wider mb-3">
              {t("about.title")}
            </h4>
            <div className="space-y-2 text-xs text-text-tertiary leading-relaxed">
              <p>
                {t("about.p1")}
              </p>
              <p>
                {t("about.p2")}
              </p>
            </div>
          </div>
        </div>
      </div>
    </div>
  );
}
