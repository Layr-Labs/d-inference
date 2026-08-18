import SwiftUI

enum SpatialFieldPresentation {
    case bloom
    case welcome

    var leadingFade: Float {
        self == .welcome ? 1 : 0
    }
}

struct SpatialFieldView: View {
    let presentation: SpatialFieldPresentation
    let focus: CGFloat
    let pointer: CGPoint
    let activity: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isCapturingDarkbloomPreview) private var isCapturingPreview
    @Environment(\.scenePhase) private var scenePhase

    private var motionIsReduced: Bool {
        reduceMotion || isCapturingPreview
    }

    private var frozenTime: TimeInterval {
        #if DEBUG
        if let value = ProcessInfo.processInfo.environment["DARKBLOOM_RENDER_PREVIEW_TIME"]
            .flatMap(Double.init)
        {
            return value
        }
        #endif
        return 23.4
    }

    private var minimumFrameInterval: TimeInterval {
        let isInteractiveWelcome = presentation == .welcome
            && (focus > 0.01 || activity > 0.01)
        return isInteractiveWelcome ? 1 / 60 : 1 / 30
    }

    private var shaderLibrary: ShaderLibrary {
        let bundledResource = Bundle.main.resourceURL?
            .appendingPathComponent("DarkbloomProvider_DarkbloomApp.bundle")

        if let bundledResource, let bundle = Bundle(url: bundledResource) {
            return .bundle(bundle)
        }
        return .bundle(.module)
    }

    init(
        presentation: SpatialFieldPresentation = .bloom,
        focus: CGFloat = 0,
        pointer: CGPoint = CGPoint(x: 0.5, y: 0.5),
        activity: CGFloat = 0
    ) {
        self.presentation = presentation
        self.focus = focus
        self.pointer = pointer
        self.activity = activity
    }

    var body: some View {
        GeometryReader { geometry in
            TimelineView(
                .animation(
                    minimumInterval: minimumFrameInterval,
                    paused: motionIsReduced || scenePhase != .active
                )
            ) { timeline in
                let time = motionIsReduced
                    ? frozenTime
                    : timeline.date.timeIntervalSinceReferenceDate
                        .truncatingRemainder(dividingBy: 120)

                Rectangle()
                    .fill(DarkbloomTheme.canvas)
                    .colorEffect(
                        shaderLibrary.darkbloomSpatialField(
                            .float2(geometry.size),
                            .float(Float(time)),
                            .float(Float(focus)),
                            .float2(Float(pointer.x), Float(pointer.y)),
                            .float(Float(activity)),
                            .float(presentation.leadingFade)
                        )
                    )
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
