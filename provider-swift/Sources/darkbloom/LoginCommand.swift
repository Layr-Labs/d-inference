import ArgumentParser
import Foundation
import ProviderCore

struct Login: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Link this machine to a Darkbloom account.",
        discussion: """
        Uses the RFC 8628 device code flow. The CLI requests a one-time code
        from the coordinator, displays it, and opens the verification URL in
        your browser. Once you authorize the code, the provider is linked to
        your account and earnings are credited to your account wallet.

        Pass --json to emit machine-readable NDJSON events on stdout (one JSON
        object per line) instead of human output — the Darkbloom macOS app's
        onboarding drives account linking through this stream. In --json mode
        stdout carries ONLY event lines (diagnostics stay on stderr) and the
        browser is NOT opened here: the calling UI deeplinks the
        verification_uri it receives in the "code" event.
        """
    )

    @OptionGroup var configOptions: ConfigOptions

    @Flag(name: .long, help: "Emit NDJSON login events on stdout for UI wrappers (suppresses human output and the automatic browser open).")
    var json = false

    mutating func run() async throws {
        let emitJSON = json
        let snapshot = try loadRuntimeSnapshot(configOptions: configOptions)
        let coordinatorURL = snapshot.config.coordinator.url

        let pollTick: (@Sendable () -> Void)?
        let onEvent: (@Sendable (DeviceLoginEvent) -> Void)?
        if emitJSON {
            pollTick = nil
            onEvent = { event in
                // stdout is the app's NDJSON channel: one line per event,
                // flushed immediately — pipe output is block-buffered, so
                // without the flush a waiting parent never sees the code.
                guard let line = try? LoginEventNDJSON.line(for: event) else { return }
                print(line)
                fflush(stdout)
            }
        } else {
            pollTick = {
                print(".", terminator: "")
                fflush(stdout)
            }
            onEvent = nil
        }

        do {
            try await performDeviceCodeLogin(
                coordinatorURL: coordinatorURL,
                onDisplayCode: { userCode, verificationURI, expiresIn in
                    guard !emitJSON else { return }
                    print()
                    print("  To link this machine, open this URL in your browser:")
                    print()
                    print("    \(verificationURI)")
                    print()
                    print("  Then enter this code:")
                    print()
                    print("    \(userCode)")
                    print()
                    print("  Waiting for approval (expires in \(expiresIn / 60) minutes)...")
                },
                onPollTick: pollTick,
                openBrowser: !emitJSON,
                onEvent: onEvent
            )

            guard !emitJSON else { return }
            print()
            print()
            print("  Account linked successfully!")
            print("  Your provider will now be connected to your account.")
            print("  Earnings will be credited to your account wallet.")
            print()
            print("  Start serving with: darkbloom start")
        } catch let error as DeviceAuthError {
            // The --json error event was already emitted by performDeviceCodeLogin;
            // this stderr line is for humans/collectors and cannot corrupt the
            // NDJSON stream.
            printError("\(error)")
            throw ExitCode.failure
        }
    }
}

/// Serialization seam between `darkbloom login --json` and its consumers.
///
/// Wire schema (one JSON object per stdout line, exactly these keys):
///   {"event":"code","user_code":"…","verification_uri":"…","expires_in":900}
///   {"event":"linked"}
///   {"event":"error","message":"…"}
///
/// The Darkbloom macOS app decodes these in
/// `Sources/DarkbloomApp/Services/AccountLinkCLI.swift` (`AccountLinkEvent`)
/// — keep both sides in sync when changing the shape.
enum LoginEventNDJSON {
    static func line(for event: DeviceLoginEvent) throws -> String {
        let object: [String: Any]
        switch event {
        case let .code(userCode, verificationURI, expiresIn):
            object = [
                "event": "code",
                "user_code": userCode,
                "verification_uri": verificationURI,
                "expires_in": expiresIn,
            ]
        case .linked:
            object = ["event": "linked"]
        case let .error(message):
            // NDJSON is line-delimited: a multi-line message would be parsed
            // as extra lines. Collapse to a single line defensively.
            object = [
                "event": "error",
                "message": message.replacingOccurrences(of: "\n", with: " "),
            ]
        }
        let data = try JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes])
        guard let line = String(data: data, encoding: .utf8), !line.contains("\n") else {
            throw SerializationError.unencodableEvent
        }
        return line
    }

    enum SerializationError: Error {
        /// JSONSerialization of a flat string/number dictionary never fails in
        /// practice; this exists so `line(for:)` stays honest instead of
        /// trapping on an impossible branch.
        case unencodableEvent
    }
}
