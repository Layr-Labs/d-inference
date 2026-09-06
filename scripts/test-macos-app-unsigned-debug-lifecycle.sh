#!/usr/bin/env bash
set -euo pipefail

# Hermetic fresh-user lifecycle smoke for an unsigned DEBUG app. The assembled
# app has the release bundle id but is unsigned and lives in a temporary
# directory. A DEBUG-only relocation bypass reaches the normal welcome screen
# without copying itself, and every app-visible path is rooted below WORK_DIR.
# This does NOT prove Developer ID identity, notarization, stapling, Gatekeeper,
# or signed-app relocation; scripts/qualify-signed-macos-app.sh qualifies a real
# release artifact without weakening any of those checks.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PACKAGE_DIR="$ROOT_DIR/provider-swift"
CONFIGURATION="${DARKBLOOM_DEBUG_LIFECYCLE_CONFIGURATION:-debug}"
VERSION="${DARKBLOOM_DEBUG_LIFECYCLE_VERSION:-0.0.0-debug-lifecycle-test}"

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/darkbloom-debug-lifecycle.XXXXXX")"
WORK_DIR="$(cd "$WORK_DIR" && pwd -P)"
APP="$WORK_DIR/Darkbloom.app"
APP_LOG="$WORK_DIR/app.log"
CLI_LOG="$WORK_DIR/fake-cli.argv"
APP_PID=""

cleanup() {
  if [[ -n "$APP_PID" ]] && kill -0 "$APP_PID" 2>/dev/null; then
    kill "$APP_PID" 2>/dev/null || true
    wait "$APP_PID" 2>/dev/null || true
  fi
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT INT TERM

if [[ "$CONFIGURATION" != "debug" ]]; then
  echo "Unsigned lifecycle smoke requires a debug DarkbloomApp build" >&2
  exit 64
fi

if [[ -n "${DARKBLOOM_DEBUG_LIFECYCLE_BIN_DIR:-}" ]]; then
  BIN_DIR="$DARKBLOOM_DEBUG_LIFECYCLE_BIN_DIR"
else
  swift build --package-path "$PACKAGE_DIR" -c "$CONFIGURATION" --product DarkbloomApp
  swift build --package-path "$PACKAGE_DIR" -c "$CONFIGURATION" --product darkbloom
  swift build --package-path "$PACKAGE_DIR" -c "$CONFIGURATION" --product darkbloom-enclave
  swift build --package-path "$PACKAGE_DIR" -c "$CONFIGURATION" --product darkbloom-fan-helper
  BIN_DIR="$(swift build --package-path "$PACKAGE_DIR" -c "$CONFIGURATION" --show-bin-path)"
fi

[[ -d "$BIN_DIR" ]] || { echo "Swift bin directory not found: $BIN_DIR" >&2; exit 1; }

# Work from copies. bundle-macos-app.sh compiles the GUI shader into the
# SwiftPM resource bundle it receives; the smoke must not mutate a shared
# .build directory while another agent or test job is using it.
STAGED_BIN_DIR="$WORK_DIR/swift-bin"
mkdir -p "$STAGED_BIN_DIR"
for executable in DarkbloomApp darkbloom darkbloom-enclave darkbloom-fan-helper; do
  [[ -x "$BIN_DIR/$executable" ]] || {
    echo "Missing built executable: $BIN_DIR/$executable" >&2
    exit 1
  }
  cp "$BIN_DIR/$executable" "$STAGED_BIN_DIR/$executable"
done

shopt -s nullglob
RESOURCE_BUNDLES=("$BIN_DIR"/*.bundle)
(( ${#RESOURCE_BUNDLES[@]} > 0 )) || {
  echo "No SwiftPM resource bundles found in $BIN_DIR" >&2
  exit 1
}
for bundle in "${RESOURCE_BUNDLES[@]}"; do
  /usr/bin/ditto "$bundle" "$STAGED_BIN_DIR/$(basename "$bundle")"
done

if [[ -n "${DARKBLOOM_DEBUG_LIFECYCLE_METALLIB:-}" ]]; then
  MLX_METALLIB="$DARKBLOOM_DEBUG_LIFECYCLE_METALLIB"
elif [[ -s "$BIN_DIR/mlx.metallib" ]]; then
  MLX_METALLIB="$BIN_DIR/mlx.metallib"
else
  METALLIB_DIR="$WORK_DIR/metallib"
  mkdir -p "$METALLIB_DIR"
  "$SCRIPT_DIR/fetch-metallib.sh" "$METALLIB_DIR"
  MLX_METALLIB="$METALLIB_DIR/mlx.metallib"
fi
[[ -s "$MLX_METALLIB" ]] || { echo "Missing non-empty mlx.metallib: $MLX_METALLIB" >&2; exit 1; }

"$SCRIPT_DIR/bundle-macos-app.sh" "$STAGED_BIN_DIR" "$MLX_METALLIB" "$APP" "$VERSION"
RESOURCE_MANIFEST="$WORK_DIR/resource-bundles.txt"
"$SCRIPT_DIR/stage-swiftpm-resource-bundles.sh" "$STAGED_BIN_DIR" "$APP" "$RESOURCE_MANIFEST"

APP_CONTENTS="$APP/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_RESOURCES="$APP_CONTENTS/Resources"
INFO_PLIST="$APP_CONTENTS/Info.plist"

for executable in DarkbloomApp darkbloom darkbloom-enclave; do
  [[ -x "$APP_MACOS/$executable" ]] || {
    echo "Bundle executable missing or not executable: $executable" >&2
    exit 1
  }
done
[[ -x "$APP_CONTENTS/Helpers/darkbloom-fan-helper" ]] || {
  echo "Bundle helper missing or not executable" >&2
  exit 1
}
cmp "$STAGED_BIN_DIR/darkbloom" "$APP_MACOS/darkbloom"
cmp "$MLX_METALLIB" "$APP_MACOS/mlx.metallib"

[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$INFO_PLIST")" == "DarkbloomApp" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$INFO_PLIST")" == "io.darkbloom.provider" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO_PLIST")" == "$VERSION" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$INFO_PLIST")" == "$VERSION" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$INFO_PLIST")" == "14.0" ]]
[[ ! -e "$APP_CONTENTS/_CodeSignature/CodeResources" ]] || {
  echo "Unsigned lifecycle smoke unexpectedly received a signed app bundle" >&2
  exit 1
}

for resource in \
  Chivo-Regular.ttf \
  Chivo-Medium.ttf \
  darkbloom-runtime-capabilities/fan-helper-v1 \
  darkbloom-runtime-capabilities/paged-kernel-v1
do
  [[ -s "$APP_RESOURCES/$resource" ]] || { echo "Missing bundle resource: $resource" >&2; exit 1; }
done
[[ -s "$RESOURCE_MANIFEST" ]] || { echo "Resource bundle manifest is empty" >&2; exit 1; }
[[ -s "$APP_RESOURCES/DarkbloomProvider_DarkbloomApp.bundle/default.metallib" ]] || {
  echo "Compiled Darkbloom GUI metallib is missing" >&2
  exit 1
}
PAGED_KERNELS=("$APP_RESOURCES"/*.bundle/pagedattention.metal)
(( ${#PAGED_KERNELS[@]} == 1 )) || {
  echo "Expected exactly one staged pagedattention.metal, found ${#PAGED_KERNELS[@]}" >&2
  exit 1
}

ISOLATED_HOME="$WORK_DIR/home"
STATE_DIR="$WORK_DIR/provider-state"
LOCAL_DIR="$WORK_DIR/local-discovery"
CONFIG_DIR="$WORK_DIR/config"
CACHE_DIR="$WORK_DIR/cache"
DATA_DIR="$WORK_DIR/data"
mkdir -p \
  "$ISOLATED_HOME/Library/Preferences" \
  "$STATE_DIR" \
  "$LOCAL_DIR" \
  "$CONFIG_DIR" \
  "$CACHE_DIR" \
  "$DATA_DIR" \
  "$WORK_DIR/tmp"

# Startup should not need the CLI. If it regresses and does, record the argv
# and fail rather than ever falling through to the co-bundled shipping CLI.
FAKE_CLI="$WORK_DIR/fail-closed-darkbloom"
cat > "$FAKE_CLI" <<'FAKE_CLI_EOF'
#!/bin/sh
printf '%s\n' "$*" >> "${DARKBLOOM_FAKE_CLI_LOG:?}"
echo "unsigned debug lifecycle forbids CLI execution during app startup" >&2
exit 97
FAKE_CLI_EOF
chmod 0755 "$FAKE_CLI"

APP_ENV=(
  "PATH=/usr/bin:/bin:/usr/sbin:/sbin"
  "TMPDIR=$WORK_DIR/tmp"
  "HOME=$ISOLATED_HOME"
  "CFFIXED_USER_HOME=$ISOLATED_HOME"
  "CFPREFERENCES_AVOID_DAEMON=1"
  "XDG_CACHE_HOME=$CACHE_DIR"
  "XDG_CONFIG_HOME=$CONFIG_DIR"
  "XDG_DATA_HOME=$DATA_DIR"
  "XDG_STATE_HOME=$STATE_DIR/xdg"
  "DARKBLOOM_CLI_PATH=$FAKE_CLI"
  "DARKBLOOM_FAKE_CLI_LOG=$CLI_LOG"
  "DARKBLOOM_STATE_FILE=$STATE_DIR/daemon-state.json"
  "DARKBLOOM_LOCAL_DIR=$LOCAL_DIR"
  "DARKBLOOM_CONFIG=$CONFIG_DIR/provider.toml"
  "DARKBLOOM_NO_UPDATE_CHECK=1"
  "DARKBLOOM_COORDINATOR_URL=http://127.0.0.1:1"
  "DARKBLOOM_CONSOLE_URL=http://127.0.0.1:1"
  "DARKBLOOM_LAUNCH_PHASE=welcome"
  "DARKBLOOM_PREVIEW_MACHINE=mac-mini"
  "DARKBLOOM_SKIP_APP_RELOCATION=1"
)

# Foundation must resolve the same isolated home that the shell advertises.
# This specifically guards FileManager.homeDirectoryForCurrentUser, which the
# relocation coordinator and CLI locator use instead of concatenating $HOME.
RESOLVED_HOME=$(
  /usr/bin/env -i "${APP_ENV[@]}" /usr/bin/swift -e \
    'import Foundation; print(FileManager.default.homeDirectoryForCurrentUser.path)'
)
[[ "$RESOLVED_HOME" -ef "$ISOLATED_HOME" ]] || {
  echo "Foundation home escaped isolation: $RESOLVED_HOME" >&2
  exit 1
}

WINDOW_PROBE="$WORK_DIR/verify-window.swift"
cat > "$WINDOW_PROBE" <<'WINDOW_PROBE_EOF'
import AppKit
import ApplicationServices
import CoreGraphics
import Darwin
import Foundation

let expectedPID = pid_t(CommandLine.arguments[1])!
let expectedBundleURL = URL(fileURLWithPath: CommandLine.arguments[2])
    .standardizedFileURL.resolvingSymlinksInPath()
let expectedExecutableURL = expectedBundleURL
    .appendingPathComponent("Contents/MacOS/DarkbloomApp")
// CGWindow bounds describe the composited surface, not NSWindow.frame. Window
// decorations can inset that surface by a few points depending on macOS. A
// 40-point tolerance still rejects the smaller launch surface; LLDB verifies
// the exact 1040x680 AppKit frame after this external readiness probe.
let minimumCGSurfaceSize = NSSize(width: 1000, height: 640)
let failureCopy = [
    "Darkbloom could not install itself",
    "Install location:",
]
let deadline = Date().addingTimeInterval(15)

struct AXSnapshot {
    let available: Bool
    let title: String?
    let strings: [String]
    let error: AXError?
}

func axAttribute(_ element: AXUIElement, _ attribute: CFString) -> (CFTypeRef?, AXError) {
    var value: CFTypeRef?
    let error = AXUIElementCopyAttributeValue(element, attribute, &value)
    return (value, error)
}

func axString(_ element: AXUIElement, _ attribute: CFString) -> String? {
    let (value, error) = axAttribute(element, attribute)
    guard error == .success else { return nil }
    return value as? String
}

func collectStrings(_ root: AXUIElement) -> [String] {
    var queue = [root]
    var seen = Set<CFHashCode>()
    var result: [String] = []

    while !queue.isEmpty && seen.count < 2_000 {
        let element = queue.removeFirst()
        let hash = CFHash(element)
        guard seen.insert(hash).inserted else { continue }

        for attribute in [kAXTitleAttribute, kAXValueAttribute, kAXDescriptionAttribute] {
            if let value = axString(element, attribute as CFString), !value.isEmpty {
                result.append(value)
            }
        }
        let (children, error) = axAttribute(element, kAXChildrenAttribute as CFString)
        if error == .success, let childElements = children as? [AXUIElement] {
            queue.append(contentsOf: childElements)
        }
    }
    return result
}

func accessibilitySnapshot() -> AXSnapshot {
    let application = AXUIElementCreateApplication(expectedPID)
    let (value, error) = axAttribute(application, kAXWindowsAttribute as CFString)
    guard error == .success else {
        return AXSnapshot(available: false, title: nil, strings: [], error: error)
    }
    guard let windows = value as? [AXUIElement], windows.count == 1 else {
        return AXSnapshot(available: true, title: nil, strings: [], error: nil)
    }
    let window = windows[0]
    return AXSnapshot(
        available: true,
        title: axString(window, kAXTitleAttribute as CFString),
        strings: collectStrings(window),
        error: nil
    )
}

func cgWindows() -> [[String: Any]] {
    let all = CGWindowListCopyWindowInfo(
        [.optionOnScreenOnly, .excludeDesktopElements],
        kCGNullWindowID
    ) as? [[String: Any]] ?? []
    return all.filter { info in
        (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == expectedPID
            && (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0
    }
}

func cgFrame(_ info: [String: Any]) -> CGRect? {
    guard let dictionary = info[kCGWindowBounds as String] as? NSDictionary else {
        return nil
    }
    return CGRect(dictionaryRepresentation: dictionary as CFDictionary)
}

var lastProblem = "no matching window observed"
var reportedAXUnavailable = false

repeat {
    guard kill(expectedPID, 0) == 0 else {
        fputs("DarkbloomApp exited while waiting for its main window\n", stderr)
        exit(1)
    }

    guard let application = NSRunningApplication(processIdentifier: expectedPID) else {
        lastProblem = "PID is alive but NSWorkspace has no running application"
        Thread.sleep(forTimeInterval: 0.1)
        continue
    }
    guard application.bundleIdentifier == "io.darkbloom.provider" else {
        fputs("unexpected running bundle id: \(application.bundleIdentifier ?? "<missing>")\n", stderr)
        exit(1)
    }
    guard application.localizedName == "Darkbloom" else {
        fputs("unexpected running app name: \(application.localizedName ?? "<missing>")\n", stderr)
        exit(1)
    }
    guard application.bundleURL?.standardizedFileURL.resolvingSymlinksInPath()
        == expectedBundleURL else {
        fputs("running app relocated away from the isolated bundle\n", stderr)
        exit(1)
    }
    guard application.executableURL?.standardizedFileURL.resolvingSymlinksInPath()
        == expectedExecutableURL else {
        fputs("running executable does not belong to the isolated bundle\n", stderr)
        exit(1)
    }
    guard application.activationPolicy == .regular else {
        lastProblem = "Darkbloom is not a regular foreground application"
        Thread.sleep(forTimeInterval: 0.1)
        continue
    }

    let windows = cgWindows()
    guard windows.count == 1, let frame = cgFrame(windows[0]) else {
        lastProblem = "expected one on-screen layer-0 window for PID, found \(windows.count)"
        Thread.sleep(forTimeInterval: 0.1)
        continue
    }
    guard frame.width >= minimumCGSurfaceSize.width,
          frame.height >= minimumCGSurfaceSize.height
    else {
        lastProblem = "CoreGraphics surface was \(frame.size), expected at least \(minimumCGSurfaceSize)"
        Thread.sleep(forTimeInterval: 0.1)
        continue
    }

    let cgTitle = windows[0][kCGWindowName as String] as? String
    if let cgTitle, cgTitle != "Darkbloom" {
        fputs("unexpected CoreGraphics window title: \(cgTitle)\n", stderr)
        exit(1)
    }

    let ax = accessibilitySnapshot()
    if ax.available {
        if let axTitle = ax.title, axTitle != "Darkbloom" {
            fputs("unexpected AX window title: \(axTitle)\n", stderr)
            exit(1)
        }
        if let forbidden = failureCopy.first(where: { forbidden in
            ax.strings.contains(where: { $0.contains(forbidden) })
        }) {
            fputs("installation failure copy is visible: \(forbidden)\n", stderr)
            exit(1)
        }
        if ax.strings.contains("Set up this Mac") {
            print("AX welcome content present; installation failure copy absent")
        } else {
            print("AX does not expose SwiftUI children; live install-state inspection will gate readiness")
        }
    } else if !reportedAXUnavailable {
        let rawError = ax.error.map { String($0.rawValue) } ?? "unknown"
        print("AX inspection unavailable (\(rawError)); using CoreGraphics identity checks")
        reportedAXUnavailable = true
    }

    let owner = windows[0][kCGWindowOwnerName as String] as? String ?? "<missing>"
    let number = (windows[0][kCGWindowNumber as String] as? NSNumber)?.intValue ?? 0
    guard owner == "Darkbloom", number > 0 else {
        fputs("unexpected main-window identity: owner=\(owner) number=\(number)\n", stderr)
        exit(1)
    }
    print("CoreGraphics surface verified: owner=Darkbloom frame=\(Int(frame.width))x\(Int(frame.height))")
    exit(0)
} while Date() < deadline

fputs("Darkbloom main-window verification timed out: \(lastProblem)\n", stderr)
exit(1)
WINDOW_PROBE_EOF

# Run the real bundled Mach-O directly under the fully isolated environment.
# AppKit still builds the same NSApplication/NSWindow from Bundle.main, while
# direct exec avoids Launch Services dropping DEBUG-only test variables (most
# importantly DARKBLOOM_SKIP_APP_RELOCATION) before the child starts.
APP_EXECUTABLE="$APP_MACOS/DarkbloomApp"
/usr/bin/env -i "${APP_ENV[@]}" "$APP_EXECUTABLE" \
  >"$APP_LOG" 2>&1 &
APP_PID=$!

sleep 0.1
if ! kill -0 "$APP_PID" 2>/dev/null; then
  echo "Isolated DarkbloomApp exited before presenting its window" >&2
  cat "$APP_LOG" >&2
  exit 1
fi

if ! /usr/bin/env -i "${APP_ENV[@]}" \
  /usr/bin/swift "$WINDOW_PROBE" "$APP_PID" "$APP"; then
  echo "DarkbloomApp did not present its exact normal-welcome main window" >&2
  cat "$APP_LOG" >&2
  exit 1
fi

# This debug binary is ad-hoc signed with get-task-allow. Inspecting it in
# process avoids depending on whether the host's TCC policy exposes SwiftUI's
# accessibility children. The delegate state is the exact switch that selects
# ContentView versus AppInstallationFailureView, and AppKit supplies the scene
# identifier/title/full frame without CoreGraphics privacy redaction.
LLDB_LOG="$WORK_DIR/lldb-window.log"
# The LLDB Swift closure's `$0` is intentionally protected from shell expansion.
# shellcheck disable=SC2016
if ! /usr/bin/env -i "${APP_ENV[@]}" /usr/bin/lldb --batch -p "$APP_PID" \
  -o 'expr -l Swift -- import AppKit' \
  -o 'expr -l Swift -O -- { let stored = Mirror(reflecting: NSApp.delegate!).children.first { $0.label == "appDelegate" }!.value; let appDelegate = Mirror(reflecting: stored).children.first!.value; return String(reflecting: Mirror(reflecting: appDelegate).children.first { $0.label == "installState" }!.value) }()' \
  -o 'expr -l objc++ -- @import AppKit' \
  -o 'expr -l objc++ -O -- ({ NSArray *windows=(NSArray *)[[NSApplication sharedApplication] windows]; NSWindow *match=nil; NSUInteger matches=0; for(NSWindow *candidate in windows){ if([candidate isVisible] && [[candidate title] isEqualToString:@"Darkbloom"]){ match=candidate; matches++; }} NSRect frame=[match frame]; [NSString stringWithFormat:@"DARKBLOOM_WINDOW|matches=%lu|title=%@|identifier=%@|frame=%.0fx%.0f|visible=%d",(unsigned long)matches,[match title],[match identifier],frame.size.width,frame.size.height,[match isVisible]]; })' \
  -o detach >"$LLDB_LOG" 2>&1; then
  echo "Could not inspect the live debug app window" >&2
  cat "$LLDB_LOG" >&2
  exit 1
fi
grep -Fq 'AppInstallLaunchState.ready' "$LLDB_LOG" || {
  echo "DarkbloomApp did not reach the ready install state" >&2
  cat "$LLDB_LOG" >&2
  exit 1
}
echo "Live install state verified: ready; installation failure view not selected"
grep -Fq \
  'DARKBLOOM_WINDOW|matches=1|title=Darkbloom|identifier=dev.darkbloom.main-window|frame=1040x680|visible=1' \
  "$LLDB_LOG" || {
  echo "DarkbloomApp in-process main-window contract did not match" >&2
  cat "$LLDB_LOG" >&2
  exit 1
}
echo "AppKit main window verified: identifier=dev.darkbloom.main-window title=Darkbloom frame=1040x680"

kill -0 "$APP_PID" 2>/dev/null || {
  echo "DarkbloomApp exited immediately after main-window verification" >&2
  cat "$APP_LOG" >&2
  exit 1
}
sleep 1
kill -0 "$APP_PID" 2>/dev/null || {
  echo "DarkbloomApp did not remain running after presenting its main window" >&2
  cat "$APP_LOG" >&2
  exit 1
}

kill "$APP_PID" 2>/dev/null || true
wait "$APP_PID" 2>/dev/null || true
APP_PID=""

[[ ! -e "$CLI_LOG" ]] || {
  echo "App startup unexpectedly invoked the CLI:" >&2
  cat "$CLI_LOG" >&2
  exit 1
}
[[ ! -e "$STATE_DIR/daemon-state.json" ]] || {
  echo "App startup unexpectedly created daemon state" >&2
  exit 1
}
[[ ! -e "$LOCAL_DIR/local.json" ]] || {
  echo "App startup unexpectedly created local endpoint discovery" >&2
  exit 1
}
[[ ! -e "$CONFIG_DIR/provider.toml" ]] || {
  echo "App startup unexpectedly created provider configuration" >&2
  exit 1
}
[[ ! -e "$ISOLATED_HOME/.darkbloom" ]] || {
  echo "App startup unexpectedly created default provider state" >&2
  exit 1
}
[[ ! -e "$ISOLATED_HOME/Applications" ]] || {
  echo "Debug relocation bypass unexpectedly created an Applications directory" >&2
  exit 1
}

echo "Unsigned debug app fresh-user lifecycle and welcome-window launch passed"
