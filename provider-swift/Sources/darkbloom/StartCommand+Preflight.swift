// Start preflight: runtime-readiness checks and the inline device-login offer.
import Foundation
import ArgumentParser
import ProviderCore
#if canImport(Darwin)
import Darwin
#endif

extension Start {
    // MARK: - Preflight Checks

    /// Runs critical doctor checks inline before the model picker so users
    /// don't discover problems *after* downloading GBs of weights.
    internal func runPreflightChecks(snapshot: RuntimeSnapshot) throws {
        warnBootSecurity(coordinatorEnforced: true)

        let debuggerAttached = checkDebuggerAttached()
        if debuggerAttached {
            printError("A debugger is attached. The coordinator will reject this provider.")
            throw ExitCode.failure
        }

        guard let hardware = snapshot.hardware else { return }
        if hardware.memoryGb < 8 {
            printError("This Mac has \(hardware.memoryGb) GB RAM. At least 8 GB is needed to serve any model.")
            throw ExitCode.failure
        }
    }

    /// Offers to link the machine to a Darkbloom account if not already logged
    /// in. Skipped in non-interactive (piped) contexts and when the user
    /// declines. This runs *before* the model picker so the auth token is
    /// available by the time the daemon starts.
    internal func offerInlineLogin(coordinatorURL: String) async {
        // Already logged in — nothing to do.
        guard AuthTokenStore.load() == nil else { return }

        // Can't prompt if stdin isn't a terminal.
        guard isatty(STDIN_FILENO) != 0 else { return }

        print()
        print("  Your provider is not linked to an account.")
        print("  Link now to receive earnings for serving inference.")
        print()
        print("  Link account? [Y/n] ", terminator: "")
        fflush(stdout)

        guard let answer = readLine()?.trimmingCharacters(in: .whitespaces) else { return }
        let declined = ["n", "no"].contains(answer.lowercased())
        if declined {
            print("  Skipped. You can link later with: darkbloom login")
            return
        }

        do {
            try await performDeviceCodeLogin(
                coordinatorURL: coordinatorURL,
                onDisplayCode: { userCode, verificationURI, expiresIn in
                    print()
                    print("  Open this URL in your browser:")
                    print()
                    print("    \(verificationURI)")
                    print()
                    print("  Then enter this code:")
                    print()
                    print("    \(userCode)")
                    print()
                    print("  Waiting for approval (expires in \(expiresIn / 60) minutes)...")
                },
                onPollTick: {
                    print(".", terminator: "")
                    fflush(stdout)
                }
            )
            print()
            print("  Account linked successfully!")
            print()
        } catch {
            print()
            print("  Could not link account: \(error)")
            print("  Continuing without account link. Run `darkbloom login` later.")
            print()
        }
    }

}
