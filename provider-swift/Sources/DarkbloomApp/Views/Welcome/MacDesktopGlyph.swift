import SwiftUI

struct MacDesktopGlyph: View {
    enum Style {
        case mini
        case studio
    }

    let style: Style

    private var height: CGFloat {
        style == .mini ? 76 : 108
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(DarkbloomTheme.ink, lineWidth: 5)

            HStack {
                HStack(spacing: 14) {
                    Capsule().frame(width: 4, height: 22)
                    Capsule().frame(width: 4, height: 22)
                    if style == .studio {
                        Capsule().frame(width: 38, height: 4)
                    }
                }

                Spacer()

                HStack(spacing: 10) {
                    Circle().frame(width: 11, height: 11)
                    if style == .mini {
                        Circle().frame(width: 16, height: 16)
                    }
                }
            }
            .foregroundStyle(DarkbloomTheme.ink)
            .padding(.horizontal, 26)
        }
        .frame(width: 190, height: height * 0.9)
        .frame(width: 210, height: 138)
    }
}
