/// GuideAvatar — Animated mascot that guides users through onboarding.
///
/// Uses SF Symbols as a placeholder. Replace the avatar image with
/// AI-generated art by adding "guide-avatar" to the asset catalog
/// and updating the `avatarImage` computed property.
///
/// The avatar has moods that change its expression and the speech
/// bubble color, making the onboarding feel alive and responsive.

import SwiftUI

// MARK: - Avatar Mood

enum AvatarMood {
    case greeting    // Welcome, first introduction
    case explaining  // Neutral, giving information
    case excited     // Something good happened (check passed, model downloaded)
    case thinking    // Processing, waiting
    case concerned   // Warning or issue detected
    case celebrating // All done, success!

    var color: Color {
        switch self {
        case .greeting: return .blueAccent
        case .explaining: return .warmInkLight
        case .excited: return .tealAccent
        case .thinking: return .gold
        case .concerned: return .warmError
        case .celebrating: return .tealAccent
        }
    }

    var imageSuffix: String {
        switch self {
        case .greeting: return "greeting"
        case .explaining: return "explaining"
        case .excited: return "excited"
        case .thinking: return "thinking"
        case .concerned: return "concerned"
        case .celebrating: return "celebrating"
        }
    }

    var symbol: String {
        switch self {
        case .greeting: return "face.smiling"
        case .explaining: return "bubble.left.fill"
        case .excited: return "hands.clap.fill"
        case .thinking: return "ellipsis.circle.fill"
        case .concerned: return "exclamationmark.triangle.fill"
        case .celebrating: return "party.popper.fill"
        }
    }
}

// MARK: - Guide Avatar View

struct GuideAvatarView: View {
    let mood: AvatarMood
    let message: String
    var detail: String?

    @State private var appeared = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // Avatar
            avatarImage
                .scaleEffect(appeared ? 1.0 : 0.5)
                .opacity(appeared ? 1 : 0)
                .animation(.spring(response: 0.5, dampingFraction: 0.7), value: appeared)

            // Speech bubble
            VStack(alignment: .leading, spacing: 4) {
                Text(message)
                    .font(.bodyWarm)
                    .fontWeight(.medium)
                    .fixedSize(horizontal: false, vertical: true)

                if let detail {
                    Text(detail)
                        .font(.captionWarm)
                        .foregroundColor(.warmInkLight)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(12)
            .background(bubbleBackground)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .offset(y: appeared ? 0 : 10)
            .opacity(appeared ? 1 : 0)
            .animation(.spring(response: 0.5, dampingFraction: 0.8).delay(0.15), value: appeared)
        }
        .onAppear { appeared = true }
        .onChange(of: message) { _, _ in
            appeared = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                appeared = true
            }
        }
    }

    // MARK: - Avatar Image

    @ViewBuilder
    private var avatarImage: some View {
        // Load mood-specific avatar from bundle resources
        let moodImageName = "guide-avatar-\(mood.imageSuffix)"
        let fallbackImageName = "guide-avatar"

        if let url = Bundle.module.url(forResource: moodImageName, withExtension: "png"),
           let nsImage = NSImage(contentsOf: url) {
            Image(nsImage: nsImage)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(mood.color.opacity(0.3), lineWidth: 2))
                .shadow(color: mood.color.opacity(0.3), radius: 6)
        } else if let url = Bundle.module.url(forResource: fallbackImageName, withExtension: "png"),
                  let nsImage = NSImage(contentsOf: url) {
            Image(nsImage: nsImage)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(mood.color.opacity(0.3), lineWidth: 2))
                .shadow(color: mood.color.opacity(0.3), radius: 6)
        } else {
            // Hand-drawn cartoon Mac character
            CartoonMac(mood: mood, size: 64)
                .shadow(color: mood.color.opacity(0.2), radius: 8)
        }
    }

    // MARK: - Bubble Background

    @ViewBuilder
    private var bubbleBackground: some View {
        if #available(macOS 26.0, *) {
            Color.clear
                .glassEffect(.regular.tint(mood.color.opacity(0.08)), in: .rect(cornerRadius: 12))
        } else {
            mood.color.opacity(0.08)
        }
    }
}

// MARK: - Guide Messages

enum GuideMessages {
    static func welcome(chipName: String, memoryGB: Int) -> (message: String, detail: String) {
        (
            "Hey! Let's set up your Mac to earn money.",
            "Your \(chipName) with \(memoryGB)GB is perfect for serving AI inference. This takes about 2 minutes."
        )
    }

    static func security(allPassed: Bool) -> (message: String, detail: String) {
        if allPassed {
            return (
                "Security checks passed!",
                "Your Mac has all the protections needed to safely process AI requests."
            )
        } else {
            return (
                "Let's check your security settings.",
                "Darkbloom needs a few macOS security features to protect the prompts being processed."
            )
        }
    }

    static func mdm(enrolled: Bool) -> (message: String, detail: String) {
        if enrolled {
            return (
                "You're verified!",
                "Your Mac is enrolled and the coordinator can verify it's genuine Apple hardware."
            )
        } else {
            return (
                "One quick step for hardware trust.",
                "This installs a lightweight profile so we can verify your Mac is genuine. It's read-only and you can remove it anytime."
            )
        }
    }

    static func model(memoryGB: Int) -> (message: String, detail: String) {
        let recommendation: String
        if memoryGB >= 64 {
            recommendation = "With \(memoryGB)GB, you can run the big models. More parameters = more earnings per request."
        } else if memoryGB >= 32 {
            recommendation = "With \(memoryGB)GB, you've got solid options. I'd go with the 14B — great balance of quality and speed."
        } else if memoryGB >= 16 {
            recommendation = "The 9B model is perfect for \(memoryGB)GB — fast, capable, and fits comfortably."
        } else {
            recommendation = "The 0.5B model is lightweight and quick. Great for getting started!"
        }
        return (
            "Pick a model to serve.",
            recommendation
        )
    }

    static func downloading(modelName: String) -> (message: String, detail: String) {
        (
            "Downloading \(modelName)...",
            "This is a one-time download. Grab a coffee — larger models take a few minutes."
        )
    }

    static func verify(passed: Bool) -> (message: String, detail: String) {
        if passed {
            return (
                "Everything looks great!",
                "All checks passed. You're ready to start earning."
            )
        } else {
            return (
                "Almost there!",
                "A few things need attention, but you can still start serving. Check the details below."
            )
        }
    }

    static let ready = (
        message: "You're all set!",
        detail: "Your Mac will start serving AI inference in the background. You'll earn while it's idle — and your Mac stays fully usable."
    )
}

