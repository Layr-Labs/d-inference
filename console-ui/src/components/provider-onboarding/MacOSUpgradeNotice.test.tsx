import { afterEach, describe, expect, it } from "vitest";
import { cleanup, render, screen } from "@testing-library/react";
import { MacOSUpgradeNotice } from "./MacOSUpgradeNotice";
import { needsMacOSUpgrade, reportedMacOSMajor } from "@/app/providers/macos-upgrade";
import { makeProvider } from "@/app/providers/dashboard/testFixtures";
import { DEFAULT_CTX, routingFor } from "@/app/providers/dashboard/routing";
import { computeWarnings } from "@/app/providers/warnings";

afterEach(cleanup);

describe("macOS upgrade notices", () => {
  it("shows the migration notice before setup", () => {
    render(<MacOSUpgradeNotice />);
    expect(screen.getByRole("heading", { name: "Upgrade to macOS 27 for setup without MDM" })).toBeInTheDocument();
    expect(screen.getByText(/Darkbloom MDM will be deactivated soon/)).toBeInTheDocument();
    expect(screen.getByText(/Existing machines can continue/)).toBeInTheDocument();
  });

  it("counts reported older Macs separately from unknown versions", () => {
    render(<MacOSUpgradeNotice providers={[
      makeProvider({ os_version: "26.5.2" }), makeProvider({ os_version: "27.0" }), makeProvider(),
    ]} />);
    expect(screen.getByRole("heading", { name: "Upgrade your Mac to macOS 27" })).toBeInTheDocument();
    expect(screen.getByText(/don’t have a macOS version for 1 machine/)).toBeInTheDocument();
  });

  it("does not label missing or malformed versions as older macOS", () => {
    for (const os_version of [undefined, "", "unknown", "27 preview", "26evil", "0.1"]) {
      expect(reportedMacOSMajor({ os_version })).toBeNull();
      expect(needsMacOSUpgrade({ os_version })).toBe(false);
    }
    render(<MacOSUpgradeNotice providers={[makeProvider()]} />);
    expect(screen.getByRole("heading", { name: "Check your Macs’ macOS versions" })).toBeInTheDocument();
  });

  it("hides the upgrade notice once all reported machines run macOS 27 or later", () => {
    render(<MacOSUpgradeNotice providers={[makeProvider({ os_version: "27.0" }), makeProvider({ os_version: "28.1" })]} />);
    expect(screen.queryByRole("complementary", { name: "macOS upgrade notice" })).not.toBeInTheDocument();
  });

  it("keeps eligible legacy machines routable while warning them to upgrade", () => {
    const provider = makeProvider({ status: "online", online: true, os_version: "26.5.2", models: [{ id: "test-model" }] });
    const warning = computeWarnings(provider, DEFAULT_CTX).find((item) => item.id === "macos_upgrade");
    expect(warning?.severity).toBe("info");
    expect(routingFor(provider, DEFAULT_CTX)).toBe("routable");
  });
});
