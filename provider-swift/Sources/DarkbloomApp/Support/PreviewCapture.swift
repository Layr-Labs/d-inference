#if DEBUG
import AppKit
import Darwin

@MainActor
enum PreviewCapture {
    static func captureIfRequested(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) async {
        guard let path = environment["DARKBLOOM_RENDER_PREVIEW_PATH"] else {
            return
        }

        let requestedDelay = environment["DARKBLOOM_RENDER_PREVIEW_DELAY"]
            .flatMap(Double.init) ?? 1.2

        // #region agent log
        debugLog(
            hypothesisId: "A",
            location: "PreviewCapture.swift:captureIfRequested-entry",
            message: "Preview capture task entered",
            data: [
                "requestedDelaySeconds": requestedDelay,
                "taskCancelled": Task.isCancelled,
                "applicationWindowCount": NSApp.windows.count,
                "visibleWindowCount": NSApp.windows.filter(\.isVisible).count,
                "launchPhase": environment["DARKBLOOM_LAUNCH_PHASE"] ?? "unset",
            ]
        )
        // #endregion

        var sleepError: NSError?
        do {
            try await Task.sleep(for: .seconds(requestedDelay))
        } catch {
            sleepError = error as NSError
        }

        // #region agent log
        debugLog(
            hypothesisId: "B",
            location: "PreviewCapture.swift:captureIfRequested-after-delay",
            message: "Preview capture delay finished",
            data: [
                "taskCancelled": Task.isCancelled,
                "sleepErrorDomain": sleepError?.domain ?? "none",
                "sleepErrorCode": sleepError?.code ?? 0,
                "applicationWindowCount": NSApp.windows.count,
                "visibleWindowCount": NSApp.windows.filter(\.isVisible).count,
            ]
        )
        // #endregion

        let url = URL(fileURLWithPath: path)
        for attempt in 0 ..< 20 {
            if writeFirstWindow(to: url, attempt: attempt) {
                // #region agent log
                debugLog(
                    hypothesisId: "E",
                    location: "PreviewCapture.swift:captureIfRequested-terminate",
                    message: "Capture accepted and termination requested",
                    data: [
                        "attempt": attempt,
                        "taskCancelled": Task.isCancelled,
                    ]
                )
                // #endregion
                NSApp.terminate(nil)
                return
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    @discardableResult
    static func writeFirstWindow(to url: URL, attempt: Int = 0) -> Bool {
        let windows = NSApp.windows
        let visibleWindows = windows.filter(\.isVisible)
        let window = visibleWindows.first
        let contentView = window?.contentView
        let representation = contentView.flatMap {
            $0.bitmapImageRepForCachingDisplay(in: $0.bounds)
        }

        // #region agent log
        debugLog(
            hypothesisId: "C",
            location: "PreviewCapture.swift:writeFirstWindow-prerequisites",
            message: "Capture prerequisites inspected",
            data: [
                "attempt": attempt,
                "applicationWindowCount": windows.count,
                "visibleWindowCount": visibleWindows.count,
                "selectedWindowNumber": window?.windowNumber ?? -1,
                "selectedWindowSharingType": window.map { Int($0.sharingType.rawValue) } ?? -1,
                "selectedWindowIsKey": window?.isKeyWindow ?? false,
                "selectedWindowIsOnActiveSpace": window?.isOnActiveSpace ?? false,
                "selectedWindowOcclusionVisible": window?.occlusionState.contains(.visible) ?? false,
                "windowFrameWidth": Double(window?.frame.width ?? 0),
                "windowFrameHeight": Double(window?.frame.height ?? 0),
                "contentViewPresent": contentView != nil,
                "contentViewType": contentView.map { String(describing: type(of: $0)) } ?? "none",
                "contentBoundsWidth": Double(contentView?.bounds.width ?? 0),
                "contentBoundsHeight": Double(contentView?.bounds.height ?? 0),
                "contentViewWantsLayer": contentView?.wantsLayer ?? false,
                "bitmapRepresentationCreated": representation != nil,
            ]
        )
        // #endregion

        guard let contentView, let representation else {
            return false
        }

        contentView.cacheDisplay(in: contentView.bounds, to: representation)
        let png = representation.representation(using: .png, properties: [:])

        // #region agent log
        debugLog(
            hypothesisId: "D",
            location: "PreviewCapture.swift:writeFirstWindow-encoded",
            message: "Cached display encoded",
            data: [
                "attempt": attempt,
                "pixelsWide": representation.pixelsWide,
                "pixelsHigh": representation.pixelsHigh,
                "bytesPerRow": representation.bytesPerRow,
                "pngCreated": png != nil,
                "pngByteCount": png?.count ?? 0,
            ]
        )
        // #endregion

        guard let png else {
            return false
        }

        var writeError: NSError?
        do {
            try png.write(to: url, options: .atomic)
        } catch {
            writeError = error as NSError
        }

        var parentIsDirectory: ObjCBool = false
        let parentExists = FileManager.default.fileExists(
            atPath: url.deletingLastPathComponent().path,
            isDirectory: &parentIsDirectory
        )

        // #region agent log
        debugLog(
            hypothesisId: "E",
            location: "PreviewCapture.swift:writeFirstWindow-write",
            message: "Atomic PNG write attempted",
            data: [
                "attempt": attempt,
                "writeSucceeded": writeError == nil,
                "writeErrorDomain": writeError?.domain ?? "none",
                "writeErrorCode": writeError?.code ?? 0,
                "outputExists": FileManager.default.fileExists(atPath: url.path),
                "parentExists": parentExists,
                "parentIsDirectory": parentIsDirectory.boolValue,
            ]
        )
        // #endregion

        // Preserve the existing DEBUG behavior while gathering evidence:
        // encoding a PNG counts as success even if the ignored write failed.
        return true
    }

    // #region agent log
    static func debugLog(
        hypothesisId: String,
        location: String,
        message: String,
        data: [String: Any]
    ) {
        let environment = ProcessInfo.processInfo.environment
        let logPath: String
        if let configuredPath = environment["DARKBLOOM_PREVIEW_DEBUG_LOG"] {
            logPath = configuredPath
        } else if let previewPath = environment["DARKBLOOM_RENDER_PREVIEW_PATH"] {
            logPath = URL(fileURLWithPath: previewPath)
                .deletingLastPathComponent()
                .appendingPathComponent("preview-debug.ndjson")
                .path
        } else {
            return
        }

        let payload: [String: Any] = [
            "hypothesisId": hypothesisId,
            "location": location,
            "message": message,
            "data": data,
            "timestamp": Int64(Date().timeIntervalSince1970 * 1_000),
        ]
        guard let encoded = try? JSONSerialization.data(withJSONObject: payload),
              let file = fopen(logPath, "a")
        else {
            return
        }
        defer { fclose(file) }
        encoded.withUnsafeBytes { bytes in
            if let baseAddress = bytes.baseAddress {
                _ = fwrite(baseAddress, 1, bytes.count, file)
            }
        }
        _ = fputc(10, file)
    }
    // #endregion
}
#endif
