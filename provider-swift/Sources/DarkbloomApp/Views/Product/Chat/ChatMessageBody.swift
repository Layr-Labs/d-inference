import AppKit
import SwiftUI

struct ChatMessageBody: View {
    let text: String
    let rendersMarkdown: Bool

    var body: some View {
        if rendersMarkdown {
            let blocks = ChatTextBlock.parse(text)
            VStack(alignment: .leading, spacing: 12) {
                ForEach(blocks.indices, id: \.self) { index in
                    switch blocks[index] {
                    case .text(let content):
                        if !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Text(inlineMarkdown(content))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    case .code(let language, let content):
                        ChatCodeBlock(language: language, content: content)
                    }
                }
            }
            .textSelection(.enabled)
        } else {
            Text(text).textSelection(.enabled)
        }
    }

    private func inlineMarkdown(_ text: String) -> AttributedString {
        (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(text)
    }
}

private struct ChatCodeBlock: View {
    let language: String
    let content: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language.isEmpty ? "Code" : language)
                    .lineLimit(1)
                Spacer()
                ChatCopyButton(text: content, label: "Copy code")
            }
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()
            ScrollView(.horizontal) {
                Text(content)
                    .font(.system(size: 13, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(12)
            }
        }
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
        .overlay { RoundedRectangle(cornerRadius: 10).stroke(ProductPalette.stroke) }
    }
}

struct ChatCopyButton: View {
    let text: String
    let label: String
    @State private var copied = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            copied = NSPasteboard.general.setString(text, forType: .string)
        } label: {
            Label(copied ? "Copied" : label, systemImage: copied ? "checkmark" : "doc.on.doc")
        }
        .buttonStyle(.borderless)
        .help(label)
        .accessibilityLabel(copied ? "Copied to clipboard" : label)
        .task(id: copied) {
            guard copied else { return }
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            copied = false
        }
    }
}
