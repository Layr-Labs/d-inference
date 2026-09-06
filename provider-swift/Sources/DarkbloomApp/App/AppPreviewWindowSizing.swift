#if DEBUG
import AppKit
import SwiftUI

/// Applies a per-launch content size after SwiftUI attaches/restores the window.
/// Ordinary launches leave native sizing and restoration untouched.
struct AppPreviewWindowSizing: NSViewRepresentable {
    let size: CGSize?

    func makeNSView(context _: Context) -> PreviewSizingView {
        PreviewSizingView()
    }

    func updateNSView(_ view: PreviewSizingView, context _: Context) {
        view.requestedSize = size
        view.applyWhenAttached()
    }

    @MainActor
    final class PreviewSizingView: NSView {
        var requestedSize: CGSize?
        private weak var configuredWindow: NSWindow?
        private var appliedSize: CGSize?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            applyWhenAttached()
        }

        func applyWhenAttached() {
            DispatchQueue.main.async { [weak self] in
                guard let self, let window, let size = requestedSize,
                      configuredWindow !== window || appliedSize != size
                else { return }
                window.setContentSize(size)
                configuredWindow = window
                appliedSize = size
            }
        }
    }
}
#endif
