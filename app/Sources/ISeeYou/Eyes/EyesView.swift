import SwiftUI

/// The fun consumer of the event stream: a pair of eyes that wander idly
/// until the presence engine says you're looking — then they look back at you.
/// Note what this view consumes: `state.engineState` only. No frames, no
/// landmarks. Any app this simple can sit on top of the platform.
struct EyesView: View {
    @ObservedObject var state: AppState

    /// Normalized pupil wander target, x/y in -1...1. Never near center —
    /// idle eyes look *away*.
    @State private var wanderTarget = CGSize(width: -0.7, height: 0.1)
    @State private var blink = false

    private let wanderTimer = Timer.publish(every: 1.7, on: .main, in: .common).autoconnect()
    private let blinkTimer = Timer.publish(every: 0.9, on: .main, in: .common).autoconnect()

    private var isWatched: Bool { state.engineState == .looking }

    private var pupilOffset: CGSize {
        isWatched ? .zero : wanderTarget
    }

    /// 1 = wide open. Droopy half-lids when nobody's around.
    private var openness: Double {
        if blink { return 0.06 }
        switch state.engineState {
        case .empty: return 0.55
        case .present: return 0.92
        case .looking: return 1.0
        }
    }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.09, green: 0.10, blue: 0.13), Color(red: 0.04, green: 0.05, blue: 0.07)],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 18) {
                HStack(spacing: 36) {
                    Eye(pupilOffset: pupilOffset, openness: openness, dilated: isWatched)
                    Eye(pupilOffset: pupilOffset, openness: openness, dilated: isWatched)
                }
                .padding(.horizontal, 40)

                Text(isWatched ? "I see you see me." : statusLine)
                    .font(.system(.title3, design: .rounded).weight(.medium))
                    .foregroundStyle(isWatched ? .primary : .tertiary)
                    .animation(.easeInOut(duration: 0.3), value: isWatched)
            }
            .padding(28)
        }
        .onAppear { state.start() }
        .onReceive(wanderTimer) { _ in
            guard !isWatched else { return }
            // New idle glance: pick a side, never the middle.
            let side: Double = Bool.random() ? 1 : -1
            withAnimation(.easeInOut(duration: 0.55)) {
                wanderTarget = CGSize(
                    width: side * Double.random(in: 0.45...0.9),
                    height: Double.random(in: -0.25...0.3)
                )
            }
        }
        .onReceive(blinkTimer) { _ in
            guard !blink, Double.random(in: 0..<1.0) < 0.22 else { return }
            withAnimation(.easeIn(duration: 0.07)) { blink = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.11) {
                withAnimation(.easeOut(duration: 0.12)) { blink = false }
            }
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.72), value: isWatched)
    }

    private var statusLine: String {
        state.engineState == .empty ? "…anyone there?" : "…"
    }
}

/// One eye, drawn in pure SwiftUI: sclera, iris, pupil, glint, eyelid.
struct Eye: View {
    var pupilOffset: CGSize   // normalized -1...1
    var openness: Double      // 0 closed ... 1 wide open
    var dilated: Bool

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let irisD = min(w, h) * (dilated ? 0.58 : 0.5)
            let pupilD = irisD * (dilated ? 0.62 : 0.44)
            let maxOffX = (w - irisD) / 2 * 0.8
            let maxOffY = (h - irisD) / 2 * 0.8

            ZStack {
                // Sclera
                Ellipse()
                    .fill(
                        RadialGradient(
                            colors: [Color.white, Color(white: 0.86)],
                            center: .center, startRadius: 0, endRadius: max(w, h) * 0.6
                        )
                    )

                // Iris + pupil + glint, travelling together
                ZStack {
                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [
                                    Color(red: 0.31, green: 0.76, blue: 0.65),
                                    Color(red: 0.10, green: 0.42, blue: 0.38),
                                ],
                                center: .center, startRadius: pupilD * 0.3, endRadius: irisD * 0.62
                            )
                        )
                        .frame(width: irisD, height: irisD)
                        .overlay(Circle().stroke(Color(red: 0.06, green: 0.25, blue: 0.22), lineWidth: 1.5))

                    Circle()
                        .fill(.black)
                        .frame(width: pupilD, height: pupilD)

                    Circle()
                        .fill(.white.opacity(0.9))
                        .frame(width: pupilD * 0.28, height: pupilD * 0.28)
                        .offset(x: -pupilD * 0.22, y: -pupilD * 0.22)
                }
                .offset(
                    x: pupilOffset.width * maxOffX,
                    y: pupilOffset.height * maxOffY
                )
                .animation(.spring(response: 0.3, dampingFraction: 0.7), value: pupilOffset)
                .animation(.spring(response: 0.35, dampingFraction: 0.6), value: dilated)

                // Eyelid drops from the top; same color as the backdrop.
                Ellipse()
                    .fill(Color(red: 0.07, green: 0.08, blue: 0.10))
                    .frame(width: w * 1.3, height: h * 1.3)
                    .offset(y: -h * (0.35 + openness))
                    .animation(.easeInOut(duration: 0.12), value: openness)
            }
            .clipShape(Ellipse())
            .overlay(Ellipse().stroke(Color(white: 0.25), lineWidth: 2))
            .shadow(color: .black.opacity(0.5), radius: 12, y: 6)
        }
        .aspectRatio(1.15, contentMode: .fit)
    }
}
