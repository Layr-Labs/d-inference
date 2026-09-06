import AppKit
import SwiftUI

struct AppInstallationProgressView: View {
    let message: String

    var body: some View {
        VStack(spacing: 16) {
            ProgressView()
            Text(message)
                .font(.headline)
        }
    }
}

struct AppInstallationFailureView: View {
    let failure: AppInstallationFailure

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 34))
                .foregroundStyle(.orange)
            Text("Darkbloom could not install itself")
                .font(.title2.bold())
            Text(failure.message)
            Text(failure.recoverySuggestion)
                .foregroundStyle(.secondary)
            Text("Install location: \(failure.destination.path)")
                .font(.callout.monospaced())
                .textSelection(.enabled)
            HStack {
                Button("Show Install Folder") {
                    NSWorkspace.shared.open(failure.destination.deletingLastPathComponent())
                }
                Button("Quit") {
                    NSApp.terminate(nil)
                }
                .keyboardShortcut(.cancelAction)
            }
        }
        .frame(maxWidth: 580, alignment: .leading)
        .padding(48)
    }
}
