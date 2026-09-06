import SwiftUI

struct ChatConversationView: View {
    let messages: [LocalChatMessage]
    let isResponding: Bool
    let isLive: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var followsOutput = true
    @State private var previousFrame: CGRect?

    var body: some View {
        GeometryReader { viewport in
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 36) {
                        ForEach(messages) { message in
                            if !message.text.isEmpty {
                                ChatMessageView(message: message, isLive: isLive)
                                    .id(message.id)
                            }
                        }
                        if isResponding { responseIndicator }
                        Color.clear.frame(height: 1).id("chat-bottom")
                    }
                    .frame(maxWidth: 840)
                    .padding(.horizontal, 40)
                    .padding(.vertical, 28)
                    .frame(maxWidth: .infinity)
                    .background {
                        GeometryReader { content in
                            Color.clear.preference(
                                key: ChatContentFrameKey.self,
                                value: content.frame(in: .named("chat-scroll"))
                            )
                        }
                    }
                }
                .coordinateSpace(name: "chat-scroll")
                .onPreferenceChange(ChatContentFrameKey.self) { frame in
                    // Growing output moves the bottom, not the top. Only an
                    // upward reading scroll disables follow; reaching the end
                    // re-enables it. This also works with wheel/trackpad input.
                    if frame.maxY <= viewport.size.height + 32 {
                        followsOutput = true
                    } else if let previousFrame, frame.minY > previousFrame.minY + 1 {
                        followsOutput = false
                    }
                    previousFrame = frame
                }
                .onAppear { proxy.scrollTo("chat-bottom", anchor: .bottom) }
                .onChange(of: messages.count) { _, _ in
                    if messages.last?.role == .user { followsOutput = true }
                    if followsOutput { proxy.scrollTo("chat-bottom", anchor: .bottom) }
                }
                .onChange(of: messages.last?.text) { _, _ in
                    if followsOutput { proxy.scrollTo("chat-bottom", anchor: .bottom) }
                }
                .onChange(of: isResponding) { _, _ in
                    if followsOutput { proxy.scrollTo("chat-bottom", anchor: .bottom) }
                }
                .overlay(alignment: .bottom) {
                    if !followsOutput {
                        Button {
                            followsOutput = true
                            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
                                proxy.scrollTo("chat-bottom", anchor: .bottom)
                            }
                        } label: {
                            Label("Jump to Latest", systemImage: "arrow.down")
                        }
                        .buttonStyle(StudioPrimaryButtonStyle())
                        .padding(12)
                    }
                }
            }
        }
    }

    private var responseIndicator: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text(isLive
                 ? (messages.last?.text.isEmpty == false && messages.last?.role == .assistant
                    ? "Responding on this Mac…" : "Waiting for the model… First replies may take longer.")
                 : "Preparing a sample reply…")
                .font(DarkbloomTheme.chivo(12))
                .foregroundStyle(StudioPalette.secondaryInk)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct ChatContentFrameKey: PreferenceKey {
    static let defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) { value = nextValue() }
}
