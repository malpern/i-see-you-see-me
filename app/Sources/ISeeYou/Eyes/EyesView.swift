import SwiftUI

/// The fun consumer of the event stream: a pair of eyes that wander idly
/// until the presence engine says you're looking — then they look back at you.
/// Note what this view consumes: `state.engineState` only. No frames, no
/// landmarks. Any app this simple can sit on top of the platform.
///
/// Movement model, loosely borrowed from how eyes actually move:
/// - Saccades: fast ballistic jumps (~120-180 ms) to a new target at
///   irregular intervals (0.5-3 s), sometimes just a small re-fixation.
/// - Fixation drift: continuous sub-degree wander while "holding" a target.
/// - Blinks: irregular, occasionally doubled.
struct EyesView: View {
    @ObservedObject var state: AppState

    /// Normalized fixation target, x/y in -1...1.
    @State private var fixation = CGSize(width: -0.6, height: 0.05)
    @State private var nextSaccadeAt = Date()
    @State private var blink = false
    @State private var nextBlinkAt = Date().addingTimeInterval(1.5)
    /// Startle reflex window after someone appears.
    @State private var startledUntil = Date.distantPast
    /// When the room emptied — drives the sleepiness ramp.
    @State private var emptySince: Date?

    private var isWatched: Bool { state.engineState == .looking }

    /// Pupil offset that points at the person's actual position in the frame.
    /// Vision coords are y-up; the camera image is unmirrored, so x flips to
    /// behave like a mirror (move left → eyes move to follow you).
    private var personTarget: CGSize {
        guard let c = state.faceCenter else { return .zero }
        let x = max(-0.8, min(0.8, (0.5 - c.x) * 1.6))
        let y = max(-0.45, min(0.45, (0.5 - c.y) * 1.0))
        return CGSize(width: x, height: y)
    }

    /// 1 = wide open, 0 = fully closed. Alone, the lids droop further the
    /// longer nobody's around (sleepiness ramp over ~90 s).
    private func opennessAt(_ now: Date) -> Double {
        if blink { return 0.0 }
        switch state.engineState {
        case .empty:
            let elapsed = now.timeIntervalSince(emptySince ?? now)
            return max(0.3, 0.62 - elapsed / 90.0 * 0.32)
        case .present: return 0.92
        case .looking: return 1.0
        }
    }

    /// Pupil dilation 0...1: attention dilates, and proximity (OAK depth)
    /// dilates further — walk up to it and the pupils visibly bloom.
    private func dilation(startled: Bool) -> Double {
        var d = isWatched ? 0.65 : 0.2
        if let mm = state.lastDistanceMM {
            let proximity = max(0, min(1, (2200.0 - Double(mm)) / 1700.0))
            d += proximity * 0.35
        }
        if startled { d += 0.3 }
        return min(1.0, d)
    }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.09, green: 0.10, blue: 0.13), Color(red: 0.04, green: 0.05, blue: 0.07)],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 18) {
                // Fixation drift: continuous, tiny, never still — this is what
                // makes them feel alive rather than animated.
                TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
                    let t = context.date.timeIntervalSinceReferenceDate
                    let driftAmp = isWatched ? 0.018 : 0.045
                    let drift = CGSize(
                        width: (sin(t * 1.9) * 0.6 + sin(t * 3.7 + 1.3) * 0.4) * driftAmp,
                        height: (cos(t * 2.3 + 0.7) * 0.6 + sin(t * 4.1) * 0.4) * driftAmp
                    )
                    // Watched: aim at the person, not an abstract center —
                    // and keep aiming as they move.
                    let base = isWatched ? personTarget : fixation
                    let offset = CGSize(width: base.width + drift.width, height: base.height + drift.height)
                    let startled = context.date < startledUntil
                    let open = opennessAt(context.date)
                    let dilate = dilation(startled: startled)

                    HStack(spacing: 36) {
                        Eye(pupilOffset: offset, openness: open, dilation: dilate)
                        Eye(pupilOffset: offset, openness: open, dilation: dilate)
                    }
                    .scaleEffect(startled ? 1.06 : 1.0)
                    .animation(.spring(response: 0.22, dampingFraction: 0.55), value: startled)
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
        .onChange(of: state.engineState) { old, new in
            if old == .empty, new != .empty {
                // Someone appeared: startle, and snap the gaze to them.
                startledUntil = Date().addingTimeInterval(0.9)
                withAnimation(.easeOut(duration: 0.12)) { fixation = personTarget }
            }
            emptySince = new == .empty ? Date() : nil
        }
        // A Combine timer property gets recreated every time AppState
        // publishes (~10 Hz with a face in frame) and never fires. .task is
        // keyed to view identity and survives re-renders.
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(120))
                let now = Date()
                saccadeIfDue(now)
                blinkIfDue(now)
            }
        }
    }

    private func saccadeIfDue(_ now: Date) {
        guard !isWatched, now >= nextSaccadeAt else { return }

        let newFixation: CGSize
        let roll = Double.random(in: 0..<1)
        if state.engineState == .present, roll < 0.3 {
            // Someone's there but not looking: sneak a glance at them.
            newFixation = personTarget
        } else if roll < 0.55 {
            // Small re-fixation near the current spot.
            newFixation = CGSize(
                width: max(-0.95, min(0.95, fixation.width + Double.random(in: -0.22...0.22))),
                height: max(-0.4, min(0.45, fixation.height + Double.random(in: -0.15...0.15)))
            )
        } else {
            // Full saccade somewhere new — usually sideways, sometimes up/down,
            // occasionally sweeping across to the other side.
            let side: Double = Double.random(in: 0..<1) < 0.6 ? (fixation.width < 0 ? 1 : -1) : (fixation.width < 0 ? -1 : 1)
            newFixation = CGSize(
                width: side * Double.random(in: 0.25...0.9),
                height: Double.random(in: -0.35...0.4)
            )
        }

        // Humans often blink during large gaze shifts.
        let jump = hypot(newFixation.width - fixation.width, newFixation.height - fixation.height)

        // Saccades are ballistic: fast out, no bounce.
        withAnimation(.easeOut(duration: Double.random(in: 0.12...0.18))) {
            fixation = newFixation
        }
        if jump > 0.7, !blink, Double.random(in: 0..<1) < 0.35 {
            runBlink()
        }
        nextSaccadeAt = now.addingTimeInterval(Double.random(in: 0.5...3.0))
    }

    /// Blinks happen in every state — watching included — at irregular
    /// intervals, with variable closed time and the occasional double blink.
    private func blinkIfDue(_ now: Date) {
        guard !blink, now >= nextBlinkAt else { return }
        runBlink()
        if Double.random(in: 0..<1) < 0.22 {
            // Double blink, then a slightly longer rest.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.38) { runBlink() }
            nextBlinkAt = now.addingTimeInterval(Double.random(in: 2.5...6.5))
        } else {
            nextBlinkAt = now.addingTimeInterval(Double.random(in: 1.2...5.5))
        }
    }

    private func runBlink() {
        // Drowsy blinks when alone are slower and stay shut longer.
        let closedFor = state.engineState == .empty
            ? Double.random(in: 0.18...0.45)
            : Double.random(in: 0.07...0.16)
        withAnimation(.easeIn(duration: 0.06)) { blink = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06 + closedFor) {
            withAnimation(.easeOut(duration: 0.13)) { blink = false }
        }
    }

    private var statusLine: String {
        state.engineState == .empty ? "…anyone there?" : "…"
    }
}

/// One eye, drawn in pure SwiftUI: sclera, iris, pupil, glint, eyelid.
struct Eye: View {
    var pupilOffset: CGSize   // normalized -1...1
    var openness: Double      // 0 closed ... 1 wide open
    var dilation: Double      // 0 constricted ... 1 fully dilated

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let irisD = min(w, h) * (0.48 + 0.10 * dilation)
            let pupilD = irisD * (0.40 + 0.28 * dilation)
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
                .animation(.spring(response: 0.45, dampingFraction: 0.8), value: dilation)

                // Eyelid drops from the top; same color as the backdrop.
                // openness 0 puts the lid's bottom edge exactly at the eye's
                // bottom — a real full blink, not a squint.
                Ellipse()
                    .fill(Color(red: 0.07, green: 0.08, blue: 0.10))
                    .frame(width: w * 1.3, height: h * 1.3)
                    .offset(y: -h * (0.15 + openness * 1.2))
                    .animation(.easeInOut(duration: 0.1), value: openness)
            }
            .clipShape(Ellipse())
            .overlay(Ellipse().stroke(Color(white: 0.25), lineWidth: 2))
            .shadow(color: .black.opacity(0.5), radius: 12, y: 6)
        }
        .aspectRatio(1.15, contentMode: .fit)
    }
}
