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
    /// Low-pass-filtered dilation: shader parameters don't get SwiftUI
    /// animation, so the pupil breathes via this smoothed value instead.
    @State private var smoothDilation = 0.3
    /// Smoothed gaze-following offset: while you're present but looking
    /// elsewhere, the eyes turn toward where your head is pointed.
    @State private var gazeFollow = CGSize.zero
    /// Transient chip naming the active sensor; shown on launch and on
    /// source switches, then fades out.
    @State private var sourceBanner: String?
    @State private var bannerDismiss: Task<Void, Never>?
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

    /// 1 = wide open, 0 = fully closed. Behavior is autonomous (state-driven
    /// openness, own blinks, sleepiness ramp) except for big actions, which
    /// punch through: blinks, sustained both-eyes closure, and wide eyes.
    private func opennessAt(_ now: Date) -> Double {
        if blink { return 0.0 }
        // Mirror sustained closure: your eyes shut, its eyes shut, until
        // yours open again.
        if state.personEyesClosed { return 0.0 }
        switch state.engineState {
        case .empty:
            let elapsed = now.timeIntervalSince(emptySince ?? now)
            return max(0.3, 0.62 - elapsed / 90.0 * 0.32)
        case .present, .looking:
            if state.personWide { return 1.2 }
            return state.engineState == .looking ? 1.0 : 0.92
        }
    }

    /// Brow height 0...1: drowsy-low alone, lifted with interest, shot up
    /// when startled — and mirroring wide eyes raises them further.
    private func browRaise(startled: Bool) -> Double {
        if startled { return 1.0 }
        let stateRaise: Double
        switch state.engineState {
        case .empty: stateRaise = 0.05
        case .present: stateRaise = 0.3
        case .looking: stateRaise = 0.6
        }
        let wideRaise = state.personWide ? 0.9 : 0.0
        return state.engineState == .empty ? stateRaise : max(stateRaise, wideRaise)
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
                    // Watched: aim at the person and keep aiming as they
                    // move. Present-but-looking-away: follow where they're
                    // looking. Empty room: wander.
                    let base: CGSize = switch state.engineState {
                    case .looking: personTarget
                    case .present: gazeFollow
                    case .empty: fixation
                    }
                    let offset = CGSize(width: base.width + drift.width, height: base.height + drift.height)
                    let startled = context.date < startledUntil
                    let open = opennessAt(context.date)
                    let dilate = smoothDilation
                    let brow = browRaise(startled: startled)

                    // Vergence: real eyes converge on what they fixate. When
                    // locked on the person, cross inward by an amount driven
                    // by their measured distance (depth sensor) — parallel
                    // gaze reads as staring through you at infinity.
                    let vergence: Double = {
                        guard isWatched else { return 0 }
                        if let mm = state.lastDistanceMM, mm > 0 {
                            return min(0.16, max(0.03, 90.0 / Double(mm)))
                        }
                        return 0.06
                    }()
                    let offsetL = CGSize(width: offset.width + vergence, height: offset.height)
                    let offsetR = CGSize(width: offset.width - vergence, height: offset.height)

                    HStack(spacing: 36) {
                        Eye(pupilOffset: offsetL, openness: open, dilation: dilate, browRaise: brow, mirrored: false, style: state.eyeStyle)
                        // Real faces aren't perfectly mirrored: the right eye
                        // runs a hair sleepier than the left.
                        Eye(pupilOffset: offsetR, openness: open * 0.97, dilation: dilate, browRaise: brow * 0.94, mirrored: true, style: state.eyeStyle)
                    }
                    .background(
                        RadialGradient(
                            colors: [Color.white.opacity(0.07), .clear],
                            center: .center, startRadius: 20, endRadius: 300
                        )
                    )
                    .scaleEffect(startled ? 1.06 : 1.0)
                    .animation(.spring(response: 0.22, dampingFraction: 0.55), value: startled)
                }
                .padding(.horizontal, 40)

                Group {
                    if let sourceBanner {
                        Label(sourceBanner, systemImage: "camera.fill")
                            .foregroundStyle(.secondary)
                    } else {
                        Text(isWatched ? "I see you see me." : statusLine)
                            .foregroundStyle(isWatched ? .primary : .tertiary)
                    }
                }
                .font(.system(.title3, design: .rounded).weight(.medium))
                .transition(.opacity)
                .animation(.easeInOut(duration: 0.3), value: isWatched)
            }
            .padding(28)
        }
        .onAppear {
            state.start()
            showSourceBanner(state.sourceKind.rawValue)
        }
        .onChange(of: state.sourceKind) { _, newSource in
            showSourceBanner(newSource.rawValue)
        }
        .onChange(of: state.blinkCount) { _, _ in
            // You blink, it blinks. The tiny delay reads as a response,
            // not a coincidence.
            guard !blink else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.09) { runBlink() }
            nextBlinkAt = Date().addingTimeInterval(Double.random(in: 1.5...4.5))
        }
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
                let target = dilation(startled: now < startledUntil)
                smoothDilation += (target - smoothDilation) * 0.22

                // Follow the person's head direction while they look around.
                // x negated so the on-screen gaze matches mirror expectations.
                // Pitch gets ~2x the gain of yaw: heads nod through a much
                // smaller range than they turn.
                let follow = CGSize(
                    width: max(-0.85, min(0.85, -state.lastYaw / 30.0)),
                    height: max(-0.7, min(0.7, state.lastPitch / 15.0))
                )
                gazeFollow.width += (follow.width - gazeFollow.width) * 0.35
                gazeFollow.height += (follow.height - gazeFollow.height) * 0.35
            }
        }
    }

    private func saccadeIfDue(_ now: Date) {
        // Wandering is for an empty room — with someone present the eyes
        // either follow their gaze or lock onto them.
        guard state.engineState == .empty, now >= nextSaccadeAt else { return }

        var newFixation: CGSize
        var holdRange: ClosedRange<Double> = 0.5...3.0
        let roll = Double.random(in: 0..<1)
        if state.engineState == .present, roll < 0.12 {
            // Someone's there but not looking: a rare, *stolen* glance —
            // brief, then darting away again.
            newFixation = personTarget
            holdRange = 0.3...0.7
        } else if roll < 0.45 {
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
                width: side * Double.random(in: 0.35...0.9),
                height: Double.random(in: -0.35...0.4)
            )
        }

        // While ignoring someone, idle gaze should stay *away* from them —
        // accidental near-misses read as staring.
        if state.engineState == .present, newFixation != personTarget {
            let toPerson = hypot(newFixation.width - personTarget.width, newFixation.height - personTarget.height)
            if toPerson < 0.45 {
                newFixation.width = personTarget.width >= 0
                    ? -Double.random(in: 0.4...0.9)
                    : Double.random(in: 0.4...0.9)
            }
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
        nextSaccadeAt = now.addingTimeInterval(Double.random(in: holdRange))
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

    private func showSourceBanner(_ name: String) {
        bannerDismiss?.cancel()
        withAnimation(.easeIn(duration: 0.25)) { sourceBanner = name }
        bannerDismiss = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.9)) { sourceBanner = nil }
        }
    }
}

/// The round style's upper eyelid: covers from the top down to a curved
/// edge following the eye's curvature (the pre-anatomy milestone look).
struct RoundLid: Shape {
    var edge: CGFloat
    var bulge: CGFloat
    var edgeOnly: Bool = false

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(edge, bulge) }
        set { edge = newValue.first; bulge = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        var p = Path()
        if edgeOnly {
            p.move(to: CGPoint(x: 0, y: edge))
            p.addQuadCurve(
                to: CGPoint(x: rect.width, y: edge),
                control: CGPoint(x: rect.midX, y: edge + bulge * 2)
            )
        } else {
            p.move(to: CGPoint(x: 0, y: -rect.height))
            p.addLine(to: CGPoint(x: 0, y: edge))
            p.addQuadCurve(
                to: CGPoint(x: rect.width, y: edge),
                control: CGPoint(x: rect.midX, y: edge + bulge * 2)
            )
            p.addLine(to: CGPoint(x: rect.width, y: -rect.height))
            p.closeSubpath()
        }
        return p
    }
}

/// The palpebral fissure — the eye opening as anatomy actually draws it.
/// An almond, not an ellipse: the upper lid arcs high with its peak slightly
/// nasal of center, the lower lid is far flatter bottoming slightly temporal,
/// and the outer corner sits a touch higher than the inner (positive canthal
/// tilt). `open` drives mostly the upper lid, as in a real blink, with a
/// small lower-lid rise; `gazeY` makes the upper lid follow vertical gaze.
struct EyeAperture: Shape {
    enum Part { case full, upper, lower }

    var open: Double      // 0 closed ... ~1.2 wide
    var gazeY: Double     // -1...1 pupil vertical; lid follows gaze
    var mirrored: Bool    // screen-right eye: nose side on its left
    var style: EyeStyle = .male
    var part: Part = .full

    var animatableData: AnimatablePair<Double, Double> {
        get { AnimatablePair(open, gazeY) }
        set { open = newValue.first; gazeY = newValue.second }
    }

    struct Anatomy {
        let inner: CGPoint
        let outer: CGPoint
        let u1: CGPoint
        let u2: CGPoint
        let l1: CGPoint
        let l2: CGPoint
    }

    static func anatomy(open: Double, gazeY: Double, mirrored: Bool, style: EyeStyle, in rect: CGRect) -> Anatomy {
        let w = rect.width
        let h = rect.height
        let openC = max(0.0, open)

        // Sexual dimorphism per the oculoplastics literature: female
        // fissures are rounder and taller with ~8.5° canthal tilt and a
        // lifted upper lid; male fissures are narrower, more rectangular,
        // ~6.5° tilt, with the lid sitting lower over the iris (deep-set).
        let female = style == .female
        let travel: CGFloat = female ? 0.40 : 0.33
        let innerCornerY: CGFloat = female ? 0.565 : 0.545
        let outerCornerY: CGFloat = female ? 0.455 : 0.505

        // Lids meet just below the horizontal midline when closed; the gaze
        // influence fades as the eye closes so the closed line is stable.
        let closeY = 0.54 * h
        let upperY = closeY - CGFloat(openC) * travel * h
            + CGFloat(gazeY * min(1.0, openC)) * 0.05 * h
        // Lower lid sits at the iris's bottom edge when open — riding higher
        // crowds the pupil and reads sleepy.
        let lowerY = closeY + 0.19 * h * CGFloat(min(1.0, openC))

        let inner = CGPoint(x: mirrored ? 0 : w, y: innerCornerY * h)
        let outer = CGPoint(x: mirrored ? w : 0, y: outerCornerY * h)

        func lerpX(_ t: CGFloat) -> CGFloat { inner.x + (outer.x - inner.x) * t }

        // Rounded arcs: upper peak near center, lower curve full.
        return Anatomy(
            inner: inner,
            outer: outer,
            u1: CGPoint(x: lerpX(0.32), y: upperY),
            u2: CGPoint(x: lerpX(0.70), y: upperY + 0.01 * h),
            l1: CGPoint(x: lerpX(0.68), y: lowerY + 0.03 * h),
            l2: CGPoint(x: lerpX(0.34), y: lowerY + 0.01 * h)
        )
    }

    /// Point on the upper-lid curve at parameter t (0 = inner corner).
    static func upperPoint(t: CGFloat, _ a: Anatomy) -> CGPoint {
        let s = 1 - t
        func bez(_ p0: CGFloat, _ p1: CGFloat, _ p2: CGFloat, _ p3: CGFloat) -> CGFloat {
            s * s * s * p0 + 3 * s * s * t * p1 + 3 * s * t * t * p2 + t * t * t * p3
        }
        return CGPoint(
            x: bez(a.inner.x, a.u1.x, a.u2.x, a.outer.x),
            y: bez(a.inner.y, a.u1.y, a.u2.y, a.outer.y)
        )
    }

    func path(in rect: CGRect) -> Path {
        let a = Self.anatomy(open: open, gazeY: gazeY, mirrored: mirrored, style: style, in: rect)
        var p = Path()
        switch part {
        case .full:
            p.move(to: a.inner)
            p.addCurve(to: a.outer, control1: a.u1, control2: a.u2)
            p.addCurve(to: a.inner, control1: a.l1, control2: a.l2)
            p.closeSubpath()
        case .upper:
            p.move(to: a.inner)
            p.addCurve(to: a.outer, control1: a.u1, control2: a.u2)
        case .lower:
            p.move(to: a.outer)
            p.addCurve(to: a.inner, control1: a.l1, control2: a.l2)
        }
        return p
    }
}

/// One eye, drawn in pure SwiftUI: brow, sclera, iris, pupil, glints, eyelid.
struct Eye: View {
    var pupilOffset: CGSize   // normalized -1...1
    var openness: Double      // 0 closed ... 1 wide open
    var dilation: Double      // 0 constricted ... 1 fully dilated
    var browRaise: Double     // 0 low/relaxed ... 1 shot up
    var mirrored: Bool        // right eye mirrors the brow tilt
    var style: EyeStyle = .male

    /// True when the packaged app contains a compiled shader library.
    static let shaderAvailable = Bundle.main.url(forResource: "default", withExtension: "metallib") != nil

    var body: some View {
        switch style {
        case .round:
            roundEye.aspectRatio(1.15, contentMode: .fit)
        case .female:
            // Rounder orbit.
            anatomicalEye.aspectRatio(1.28, contentMode: .fit)
        case .male:
            // Narrower, more rectangular fissure.
            anatomicalEye.aspectRatio(1.42, contentMode: .fit)
        }
    }

    private var anatomicalEye: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let rect = CGRect(x: 0, y: 0, width: w, height: h)
            let irisD = min(w, h) * 0.58
            let pupilD = irisD * (0.38 + 0.26 * dilation)
            let anatomy = EyeAperture.anatomy(
                open: openness, gazeY: pupilOffset.height, mirrored: mirrored, style: style, in: rect
            )

            ZStack {
                eyeball(w: w, h: h, irisD: irisD, pupilD: pupilD, dressed: true)
                    .clipShape(EyeAperture(open: openness, gazeY: pupilOffset.height, mirrored: mirrored, style: style))
                    .shadow(color: .black.opacity(0.45), radius: 10, y: 5)
                lidLines(w: w, h: h)
                lashes(h: h, anatomy: anatomy)
                brow(w: w, h: h)
            }
            .animation(.easeInOut(duration: 0.09), value: openness)
        }
    }

    /// The cartoon look from the pre-anatomy milestone: ellipse eyes with a
    /// curved descending lid, a lid line, and three lashes — no lower lid.
    private var roundEye: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let irisD = min(w, h) * 0.54
            let pupilD = irisD * (0.34 + 0.24 * dilation)
            let lidEdge = h * (0.08 + (1.0 - openness) * 0.96)

            ZStack {
                ZStack {
                    eyeball(w: w, h: h, irisD: irisD, pupilD: pupilD, dressed: false)
                    // Soft top shading, then the lid descending to a curved
                    // edge that follows the eye's curvature.
                    Ellipse()
                        .fill(
                            LinearGradient(
                                colors: [.black.opacity(0.25), .clear],
                                startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.45)
                            )
                        )
                    RoundLid(edge: lidEdge, bulge: h * 0.10)
                        .fill(Color(red: 0.07, green: 0.08, blue: 0.10))
                }
                .clipShape(Ellipse())
                .overlay(Ellipse().stroke(Color(white: 0.25), lineWidth: 2))
                .shadow(color: .black.opacity(0.5), radius: 12, y: 6)

                roundLidDressing(w: w, h: h, edge: lidEdge)
                brow(w: w, h: h)
            }
            .animation(.easeInOut(duration: 0.09), value: openness)
        }
    }

    /// Lid line + lashes for the round style, clamped to the ellipse's width
    /// at the lid's height so nothing floats beyond the eye outline.
    private func roundLidDressing(w: CGFloat, h: CGFloat, edge: CGFloat) -> some View {
        let yNorm = 1 - 2 * min(h, edge + h * 0.05) / h
        let halfW = (w / 2) * sqrt(max(0.05, 1 - yNorm * yNorm))
        let lineW = halfW * 2
        let lashY = { (t: CGFloat) in edge + 2 * t * (1 - t) * (h * 0.10) * 2 }
        let ts: [CGFloat] = mirrored ? [0.78, 0.88, 0.97] : [0.22, 0.12, 0.03]
        let angles: [Double] = mirrored ? [22, 34, 48] : [-22, -34, -48]

        return ZStack {
            RoundLid(edge: edge, bulge: h * 0.08, edgeOnly: true)
                .stroke(Color(white: 0.30), style: StrokeStyle(lineWidth: h * 0.03, lineCap: .round))
                .frame(width: lineW, height: h)
            ForEach(0..<3, id: \.self) { i in
                Capsule()
                    .fill(Color(red: 0.16, green: 0.14, blue: 0.13))
                    .frame(width: h * 0.022, height: h * 0.13)
                    .rotationEffect(.degrees(angles[i]), anchor: .bottom)
                    .position(x: ts[i] * lineW, y: lashY(ts[i]) - h * 0.065)
            }
            .frame(width: lineW, height: h)
        }
        .frame(width: w, height: h)
    }

    /// Lid margin, supratarsal crease, and lower-lid line — the three
    /// strokes that make a lid read as skin with thickness, not a shutter.
    private func lidLines(w: CGFloat, h: CGFloat) -> some View {
        ZStack {
            // Upper lid margin: the visible thickness of the lid edge.
            EyeAperture(open: openness, gazeY: pupilOffset.height, mirrored: mirrored, style: style, part: .upper)
                .stroke(
                    Color(red: 0.30, green: 0.26, blue: 0.24),
                    style: StrokeStyle(lineWidth: h * 0.045, lineCap: .round)
                )
            // Supratarsal crease: HIGH in the female lid (visible pretarsal
            // platform), LOW and hugging the margin in the male lid (full
            // upper lid, little show).
            EyeAperture(
                open: min(1.4, openness + (style == .female ? 0.46 : 0.16)),
                gazeY: pupilOffset.height * 0.6,
                mirrored: mirrored, style: style, part: .upper
            )
            .stroke(
                Color(white: 0.20),
                style: StrokeStyle(lineWidth: h * 0.02, lineCap: .round)
            )
            // Lower lid: present but quiet.
            EyeAperture(open: openness, gazeY: pupilOffset.height, mirrored: mirrored, style: style, part: .lower)
                .stroke(
                    Color(white: 0.30).opacity(0.7),
                    style: StrokeStyle(lineWidth: h * 0.022, lineCap: .round)
                )
        }
    }

    /// Lashes anchored to the actual upper-lid curve, flaring outward from
    /// the temporal half, riding the lid through every blink. The female
    /// style gets a fuller, longer set.
    private func lashes(h: CGFloat, anatomy: EyeAperture.Anatomy) -> some View {
        let female = style == .female
        let ts: [CGFloat] = female ? [0.66, 0.77, 0.87, 0.96] : [0.74, 0.85, 0.95]
        let baseAngles: [Double] = female ? [14, 24, 36, 50] : [20, 33, 47]
        let angles = mirrored ? baseAngles : baseAngles.map { -$0 }
        let lashLen = h * (female ? 0.19 : 0.14)
        return ForEach(0..<ts.count, id: \.self) { i in
            let pt = EyeAperture.upperPoint(t: ts[i], anatomy)
            Capsule()
                .fill(Color(red: 0.16, green: 0.14, blue: 0.13))
                .frame(width: h * 0.022, height: lashLen)
                .rotationEffect(.degrees(angles[i]), anchor: .bottom)
                .position(x: pt.x, y: pt.y - lashLen / 2)
        }
    }

    /// The brow is the strongest sex cue: male brows are thick, flat, and
    /// sit low on the orbital rim close to the eye; female brows are thin,
    /// set higher, and arch with the peak at the lateral third.
    private func brow(w: CGFloat, h: CGFloat) -> some View {
        let female = style == .female
        // A shallower source ellipse flattens the male arc.
        let archHeight: CGFloat = female ? 1.0 : 0.62
        let thickness: CGFloat = female ? 0.040 : 0.078
        let lift: CGFloat = female ? 0.20 : 0.07
        // Lateral-third peak: tilt the arc so the outer end rides higher.
        let lateralTilt: Double = female ? 5 : 1

        return Ellipse()
            .trim(from: 0.62, to: 0.88)
            .stroke(
                Color(white: female ? 0.40 : 0.45),
                style: StrokeStyle(lineWidth: h * thickness, lineCap: .round)
            )
            .frame(width: w * 0.96, height: h * (archHeight - browRaise * 0.12))
            .offset(y: -h * (lift + browRaise * 0.16) + pupilOffset.height * h * 0.03)
            .rotationEffect(.degrees((mirrored ? -1 : 1) * (browRaise * 3 + lateralTilt)))
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: browRaise)
    }

    private func eyeball(
        w: CGFloat, h: CGFloat, irisD: CGFloat, pupilD: CGFloat, dressed: Bool
    ) -> some View {
            let maxOffX = (w - irisD) / 2 * 0.75
            let maxOffY = h * 0.14
            return ZStack {
                // Sclera — shader-lit as a sphere (warm off-white, corner
                // vasculature, socket falloff); flat gradient as fallback.
                if Self.shaderAvailable {
                    Ellipse()
                        .fill(.white)
                        .colorEffect(ShaderLibrary.default.sclera(
                            .float2(Float(w), Float(h))
                        ))
                } else {
                    Ellipse()
                        .fill(
                            RadialGradient(
                                colors: [Color.white, Color(white: 0.86)],
                                center: .center, startRadius: 0, endRadius: max(w, h) * 0.6
                            )
                        )
                }

                // Iris + pupil (procedural Metal shader) + glints, travelling
                // together. The shader draws fibers, collarette, limbal ring,
                // and the pupil itself — dilation is a shader parameter.
                // Falls back to vector art when no metallib ships in the
                // bundle (Metal Toolchain not installed at build time).
                ZStack {
                    if Self.shaderAvailable {
                        Circle()
                            .fill(.white)
                            .frame(width: irisD, height: irisD)
                            .colorEffect(ShaderLibrary.default.iris(
                                .float2(Float(irisD), Float(irisD)),
                                .float(Float(dilation))
                            ))
                    } else {
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
                    }

                    // Primary glint + a faint secondary, like a second light
                    // source. Counter-offset against gaze: a catchlight is a
                    // reflection of the room, so it mostly stays put while
                    // the eyeball rotates underneath it.
                    Group {
                        Circle()
                            .fill(.white.opacity(0.9))
                            .frame(width: pupilD * 0.28, height: pupilD * 0.28)
                            .offset(x: -pupilD * 0.22, y: -pupilD * 0.22)
                        Circle()
                            .fill(.white.opacity(0.35))
                            .frame(width: pupilD * 0.14, height: pupilD * 0.14)
                            .offset(x: pupilD * 0.26, y: pupilD * 0.24)
                    }
                    .offset(
                        x: -pupilOffset.width * maxOffX * 0.45,
                        y: -pupilOffset.height * maxOffY * 0.45
                    )
                }
                .offset(
                    x: pupilOffset.width * maxOffX,
                    y: pupilOffset.height * maxOffY
                )
                .animation(.spring(response: 0.45, dampingFraction: 0.8), value: dilation)

                if dressed {
                    // Ambient occlusion: the soft shadow the upper lid casts
                    // on the eyeball. Heavier for the male style — deep-set
                    // shadowed eyes are a masculine marker.
                    EyeAperture(open: openness, gazeY: pupilOffset.height, mirrored: mirrored, style: style, part: .upper)
                        .stroke(Color.black.opacity(style == .female ? 0.26 : 0.42), lineWidth: h * (style == .female ? 0.10 : 0.15))
                        .blur(radius: h * 0.05)
                        .offset(y: h * 0.015)

                    // Caruncle: the small pink tissue at the inner corner.
                    Ellipse()
                        .fill(Color(red: 0.78, green: 0.50, blue: 0.48))
                        .frame(width: w * 0.06, height: h * 0.10)
                        .position(
                            x: (mirrored ? 0 : w) + (mirrored ? 1 : -1) * w * 0.022,
                            y: h * 0.55
                        )
                }
            }
    }
}
