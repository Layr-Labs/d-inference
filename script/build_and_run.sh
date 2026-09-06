#!/usr/bin/env bash
set -euo pipefail

APP_NAME="Darkbloom"
PROCESS_NAME="DarkbloomApp"
BUNDLE_ID="dev.darkbloom.app"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
PACKAGE_DIR="$ROOT_DIR/provider-swift"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/$PROCESS_NAME"
MODE="run"
BUILD=1
PREVIEW_DESTINATION=""
STAGING_DIR=""
PRESERVE_STAGING=0
LOCK_DIR="$DIST_DIR/.darkbloom-run.lock"
LOCK_TOKEN="owner-$$-$RANDOM-$RANDOM"
LOCK_OWNED=0
RECOVER_LOCK=0

fail() {
  printf '%s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'USAGE'
Usage: ./script/build_and_run.sh [run|--debug|--logs|--telemetry|--verify]
                                 [--no-build] [--preview DESTINATION]
       ./script/build_and_run.sh --recover-lock

Builds a debug app, stages dist/Darkbloom.app, then replaces only this
checkout's running app. Build or staging failures leave the current app intact.
--no-build     Relaunch a known debug bundle staged by this script.
--recover-lock Remove a lock whose recorded owner has exited, then exit.
--preview      Use fixture product services (e.g. overview, chat, my-macs).
               Existing exported DARKBLOOM_* preview/capture settings also work.
               DARKBLOOM_PREVIEW_APPEARANCE=light|dark affects only this app.
               DARKBLOOM_PREVIEW_WINDOW_WIDTH/HEIGHT set preview content size.
--debug        Launch the app bundle, then attach lldb to its exact PID.
--logs         Stream logs for that PID.
--telemetry    Stream that PID's dev.darkbloom.app subsystem logs.
--verify       Wait for that PID's visible main-sized window (900 x 620 minimum).
USAGE
}

# Validate all options before building, staging, or asking any app to quit.
while (($#)); do
  case "$1" in
    run|debug|logs|telemetry|verify|--debug|--logs|--telemetry|--verify)
      MODE="${1#--}"
      ;;
    --no-build) BUILD=0 ;;
    --recover-lock) RECOVER_LOCK=1 ;;
    --preview)
      (($# >= 2)) || fail "--preview requires a product destination."
      case "$2" in
        overview|chat|network-overview|local-api|my-macs|contributions|availability|activity|models|machine)
          PREVIEW_DESTINATION="$2"
          ;;
        *) fail "Unknown preview destination: $2" ;;
      esac
      shift
      ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; fail "Unknown argument: $1" ;;
  esac
  shift
done

[[ "$(uname -s)" == Darwin ]] || fail "This workflow requires macOS."
[[ ! -L "$DIST_DIR" && ! -L "$APP_BUNDLE" ]] || fail "Refusing a symlinked dist directory or app bundle."
[[ ! -L "$LOCK_DIR" ]] || fail "Refusing a symlinked run lock."

recover_lock() {
  [[ -d "$LOCK_DIR" ]] || fail "No run lock to recover."
  local entries=("$LOCK_DIR"/owner-*)
  [[ ${#entries[@]} == 1 && -d "${entries[0]}" && ! -L "${entries[0]}" ]] || fail "Lock has no unique owner record; inspect it manually without removing an active run's lock."
  local token="${entries[0]##*/}"
  local owner_pid="${token#owner-}"
  owner_pid="${owner_pid%%-*}"
  case "$owner_pid" in
    ''|*[!0-9]*|0) fail "Invalid lock owner record; inspect it manually." ;;
  esac
  # A reused PID is treated as live too. ps also detects a live owner belonging
  # to another UID, for which kill -0 can fail with a permissions error.
  local owner_process owner_status=0
  owner_process="$(/bin/ps -p "$owner_pid" -o pid= 2>/dev/null)" || owner_status=$?
  if [[ -n "$owner_process" ]] || kill -0 "$owner_pid" 2>/dev/null; then
    fail "Run PID $owner_pid still exists; leaving its lock untouched."
  fi
  [[ "$owner_status" == 1 ]] || fail "Could not establish that run PID $owner_pid exited; leaving its lock untouched."
  # Remove only the exact owner token observed above. A concurrent recovery
  # cannot remove a later run's different token (or its nonempty lock directory).
  rmdir "${entries[0]}" || fail "Lock ownership changed; retry recovery."
  rmdir "$LOCK_DIR" || fail "Lock contents changed; inspect them before retrying."
  printf 'Recovered stale run lock for exited PID %s.\n' "$owner_pid"
}

if ((RECOVER_LOCK)); then
  recover_lock
  exit 0
fi

release_lock() {
  if ((LOCK_OWNED)); then
    if ! rmdir "$LOCK_DIR/$LOCK_TOKEN" || ! rmdir "$LOCK_DIR"; then
      printf 'Could not release the run lock; inspect %s.\n' "$LOCK_DIR" >&2
    fi
    LOCK_OWNED=0
  fi
}

mkdir -p "$DIST_DIR"
mkdir "$LOCK_DIR" 2>/dev/null || fail "Another run owns $LOCK_DIR. After its owner exits, use --recover-lock."
mkdir "$LOCK_DIR/$LOCK_TOKEN" || fail "Could not record run-lock ownership; inspect $LOCK_DIR."
LOCK_OWNED=1
cleanup() {
  if [[ -n "$STAGING_DIR" ]]; then
    if ((PRESERVE_STAGING)) && [[ -e "$STAGING_DIR/previous.app" ]]; then
      printf 'Previous app bundle preserved in %s/previous.app\n' "$STAGING_DIR" >&2
    else
      rm -rf "$STAGING_DIR"
    fi
  fi
  release_lock
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

validate_bundle() {
  local bundle="$1"
  local plist="$bundle/Contents/Info.plist"
  [[ -x "$bundle/Contents/MacOS/$PROCESS_NAME" ]] || fail "Missing executable in $bundle; run without --no-build."
  /usr/bin/plutil -lint "$plist" >/dev/null
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$plist")" == "$PROCESS_NAME" ]] || fail "Unexpected bundle executable."
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$plist")" == "$BUNDLE_ID" ]] || fail "Refusing a non-development app bundle."
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundlePackageType' "$plist")" == APPL ]] || fail "Not an application bundle."
  local build_configuration
  build_configuration="$(/usr/libexec/PlistBuddy -c 'Print :DarkbloomLocalBuildConfiguration' "$plist" 2>/dev/null || true)"
  [[ "$build_configuration" == debug ]] || fail "A known debug bundle staged by this script is required; run once without --no-build."
  [[ -f "$bundle/Contents/Resources/DarkbloomProvider_DarkbloomApp.bundle/default.metallib" ]] || fail "Missing staged Metal library; run without --no-build."
}

stage_app() {
  swift build --package-path "$PACKAGE_DIR" --configuration debug --product "$PROCESS_NAME"
  local build_dir
  build_dir="$(swift build --package-path "$PACKAGE_DIR" --configuration debug --show-bin-path)"
  local resource_bundle="$build_dir/DarkbloomProvider_DarkbloomApp.bundle"
  [[ -x "$build_dir/$PROCESS_NAME" && -d "$resource_bundle" ]] || fail "SwiftPM did not produce the app and its resource bundle."

  STAGING_DIR="$(mktemp -d "$DIST_DIR/.darkbloom-build.XXXXXX")"
  local contents="$STAGING_DIR/$APP_NAME.app/Contents"
  local resources="$contents/Resources"
  mkdir -p "$contents/MacOS" "$resources"
  cp "$build_dir/$PROCESS_NAME" "$contents/MacOS/$PROCESS_NAME"
  chmod +x "$contents/MacOS/$PROCESS_NAME"
  cp "$PACKAGE_DIR/Resources/DarkbloomApp/Info.plist" "$contents/Info.plist"
  cp "$PACKAGE_DIR/Resources/DarkbloomApp/Chivo-Regular.ttf" "$resources/"
  cp "$PACKAGE_DIR/Resources/DarkbloomApp/Chivo-Medium.ttf" "$resources/"
  /usr/bin/ditto "$resource_bundle" "$resources/$(basename "$resource_bundle")"

  # Compile into the staged copy; never modify SwiftPM's shared build resources.
  local staged_resources
  staged_resources="$resources/$(basename "$resource_bundle")"
  xcrun -sdk macosx metal -c "$PACKAGE_DIR/Sources/DarkbloomApp/Resources/DarkbloomSpatialField.metal" -o "$STAGING_DIR/SpatialField.air"
  xcrun -sdk macosx metallib "$STAGING_DIR/SpatialField.air" -o "$staged_resources/default.metallib"
  /usr/libexec/PlistBuddy -c 'Add :DarkbloomLocalBuildConfiguration string debug' "$contents/Info.plist"
  validate_bundle "$STAGING_DIR/$APP_NAME.app"
}

# NSRunningApplication supplies both the bundle and executable URL. Names and
# bundle identifiers alone can also identify another checkout or installed app.
# The Swift helper is interpreted; --no-build skips SwiftPM and shader builds.
app_control() {
  swift - "$1" "$APP_BINARY" "$APP_BUNDLE" "$MODE" <<'SWIFT'
import AppKit
import CoreGraphics
import Foundation

let operation = CommandLine.arguments[1]
let executable = URL(fileURLWithPath: CommandLine.arguments[2]).standardizedFileURL
let bundle = URL(fileURLWithPath: CommandLine.arguments[3]).standardizedFileURL
let mode = CommandLine.arguments[4]

func report(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

func fail(_ message: String) -> Never {
    report(message)
    exit(1)
}

func hasExpectedLocation(_ app: NSRunningApplication) -> Bool {
    app.executableURL?.standardizedFileURL == executable
        && app.bundleURL?.standardizedFileURL == bundle
}

func matches(_ app: NSRunningApplication) -> Bool {
    !app.isTerminated && hasExpectedLocation(app)
}

func checkoutApps() -> [NSRunningApplication] {
    NSWorkspace.shared.runningApplications.filter(matches)
}

func tick() {
    // AppKit updates running-application properties on the main run loop.
    RunLoop.current.run(until: Date().addingTimeInterval(0.1))
}

func hasMainWindow(pid: pid_t) -> Bool {
    let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
        as? [[String: Any]] ?? []
    return windows.contains { window in
        guard (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
              (window[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
              let bounds = window[kCGWindowBounds as String] as? [String: Any],
              let width = bounds["Width"] as? NSNumber,
              let height = bounds["Height"] as? NSNumber
        else { return false }
        return width.doubleValue >= 900 && height.doubleValue >= 620
    }
}

if operation == "stop" {
    let apps = checkoutApps()
    for app in apps {
        report("Requesting termination of checkout PID \(app.processIdentifier): \(executable.path)")
        if matches(app), !app.terminate(), !app.isTerminated {
            fail("Could not request termination of checkout PID \(app.processIdentifier).")
        }
    }
    let deadline = Date().addingTimeInterval(10)
    while !checkoutApps().isEmpty && Date() < deadline { tick() }
    guard checkoutApps().isEmpty else {
        fail("The checkout app did not quit within 10 seconds; its bundle was not replaced.")
    }
    exit(0)
}

guard operation == "launch" else { fail("Unknown app-control operation.") }
guard checkoutApps().isEmpty else { fail("The checkout app started concurrently; refusing a duplicate launch.") }
let environment = ProcessInfo.processInfo.environment
report("Opening checkout bundle: \(bundle.path)")
report("Preview controls: destination=\(environment["DARKBLOOM_PREVIEW_PRODUCT_DESTINATION"] ?? "unset"), appearance=\(environment["DARKBLOOM_PREVIEW_APPEARANCE"] ?? "unset"), contentSize=\(environment["DARKBLOOM_PREVIEW_WINDOW_WIDTH"] ?? "default")x\(environment["DARKBLOOM_PREVIEW_WINDOW_HEIGHT"] ?? "default"), captureRequested=\(environment["DARKBLOOM_RENDER_PREVIEW_PATH"] != nil)")
let opener = Process()
opener.executableURL = URL(fileURLWithPath: "/usr/bin/open")
opener.arguments = ["-n", bundle.path]
// Keep command substitution's stdout reserved for the verified PID.
opener.standardOutput = FileHandle.standardError
do { try opener.run() } catch { fail("Could not open \(bundle.path): \(error)") }
opener.waitUntilExit()
guard opener.terminationStatus == 0 else { fail("open failed for \(bundle.path).") }

let deadline = Date().addingTimeInterval(20)
var launchedApp: NSRunningApplication?
while Date() < deadline {
    let apps = checkoutApps()
    guard apps.count <= 1 else { fail("Multiple apps launched from the checkout; refusing an ambiguous PID.") }
    if launchedApp == nil, let candidate = apps.first {
        launchedApp = candidate
        report("Observed checkout PID \(candidate.processIdentifier): \(candidate.executableURL?.path ?? "unavailable")")
    }
    if let app = launchedApp {
        guard !app.isTerminated else {
            fail("AppKit reports checkout PID \(app.processIdentifier) terminated before verification. Current matching PIDs: \(apps.map(\.processIdentifier)).")
        }
        guard hasExpectedLocation(app) else {
            fail("Checkout PID \(app.processIdentifier) no longer reports the expected location; executable=\(app.executableURL?.path ?? "unavailable"), bundle=\(app.bundleURL?.path ?? "unavailable"). Termination was not reported.")
        }
        if app.isFinishedLaunching && (mode != "verify" || hasMainWindow(pid: app.processIdentifier)) {
            print(app.processIdentifier)
            exit(0)
        }
    }
    tick()
}
if let app = launchedApp {
    fail("Checkout PID \(app.processIdentifier) did not finish launching with the requested window within 20 seconds.")
}
fail("No running application found at \(executable.path) within 20 seconds.")
SWIFT
}

if ((BUILD)); then
  stage_app
else
  validate_bundle "$APP_BUNDLE"
fi

if [[ -n "$PREVIEW_DESTINATION" ]]; then
  export DARKBLOOM_PREVIEW_PRODUCT_DESTINATION="$PREVIEW_DESTINATION"
fi

app_control stop
if ((BUILD)); then
  # Keep the previous bundle through launch verification, including interrupts.
  # A failed launch may still have a running process, so preserve the backup
  # at its reported path rather than replacing that process's bundle underneath it.
  if [[ -e "$APP_BUNDLE" ]]; then
    PRESERVE_STAGING=1
    mv "$APP_BUNDLE" "$STAGING_DIR/previous.app"
  fi
  if ! mv "$STAGING_DIR/$APP_NAME.app" "$APP_BUNDLE"; then
    if [[ -d "$STAGING_DIR/previous.app" ]]; then
      mv "$STAGING_DIR/previous.app" "$APP_BUNDLE"
      PRESERVE_STAGING=0
    fi
    fail "Could not publish the staged app bundle."
  fi
fi

APP_PID="$(app_control launch)"
PRESERVE_STAGING=0
# Debuggers and log streams can outlive this app; they must not block relaunch.
release_lock
printf 'Launched PID %s: %s\n' "$APP_PID" "$APP_BINARY"
case "$MODE" in
  debug) lldb -p "$APP_PID" ;;
  logs) /usr/bin/log stream --info --style compact --predicate "processIdentifier == $APP_PID" ;;
  telemetry) /usr/bin/log stream --info --style compact --predicate "processIdentifier == $APP_PID AND subsystem == \"$BUNDLE_ID\"" ;;
  verify) printf 'Verified the checkout PID, executable path, and visible main window.\n' ;;
esac
