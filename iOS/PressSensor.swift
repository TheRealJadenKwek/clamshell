import Foundation

/// Turns one finger's touch samples into a press stage, like the two detents of a
/// MacBook trackpad: a click, then a deeper Force Click.
///
/// iPhone glass does not sense pressure, but a fingertip flattens as it presses
/// harder, so the contact gets bigger. We compare the contact size with the size
/// the finger had when it was resting. On hardware that does report pressure we
/// use that instead.
struct PressSensor {
    enum Stage: Int { case rest = 0, click = 1, force = 2 }

    struct Sample {
        var time: TimeInterval
        var radius: Double    // UITouch.majorRadius, points
        var force: Double     // UITouch.force, 0 when the hardware has none
        var maxForce: Double  // UITouch.maximumPossibleForce, 0 when the hardware has none
        var speed: Double     // finger speed in points per second, smoothed by the caller
    }

    /// 0 light, 1 medium, 2 firm.
    var pressure: Int
    /// When false the press stops at a click.
    var forceEnabled: Bool
    /// A press is measured against at least this size, whatever size this touch landed with: the size a
    /// resting fingertip has on this iPhone (see `RestingSize`). 0 for none.
    var restFloor: Double
    /// The steps this iPhone reports contact size in (see `RestingSize.step`), or 0 when it is fine grained.
    var step: Double

    private(set) var stage: Stage = .rest
    private(set) var baseline: Double = 0
    private(set) var minRadius: Double = 0
    private(set) var maxRadius: Double = 0
    private(set) var peakLevel: Double = 0
    private(set) var peakForce: Double = 0
    private(set) var usedRealForce = false
    /// The deepest stage this touch reached.
    private(set) var deepest: Stage = .rest
    /// How long this touch has lasted since it landed, and how much of that its contact was a single step.
    private(set) var heldSeconds: Double = 0
    private(set) var smallSeconds: Double = 0

    private var startTime: TimeInterval?
    private var lastTime: TimeInterval = 0
    private var lowSince: TimeInterval?
    /// Since when the finger has been both still and at its resting size, without a break.
    private var calmSince: TimeInterval?
    /// While the contact is above the click size: whether it stepped up from a calm finger. Judged once per rise.
    private var riseCalm: Bool?
    /// This touch for the report: "milliseconds:steps:speed" for each size change, and "milliseconds:C:speed"
    /// for a click or "milliseconds:R:speed" for a rise that was not taken as a press.
    private(set) var trace: [String] = []
    private var tracedRadius: Double = -1

    /// The finger is still landing for this long; its size then is its resting size.
    static let landing: TimeInterval = 0.07
    /// A press cannot start this early, so a quick tap never clicks twice.
    static let minAge: TimeInterval = 0.09
    /// A press cannot start while the finger is gliding this fast.
    static let maxStartSpeed: Double = 250
    /// Medium, on coarse hardware: the finger counts as still below this speed, and it must have been still
    /// and at its resting size for `calmBefore` right up to the moment its contact stepped up. A fingertip
    /// also reads a step bigger when it flattens during a glide, and that is not a press.
    static let stillSpeed: Double = 90
    static let calmBefore: TimeInterval = 0.06
    /// Pressing rolls the fingertip a little, so the sample that steps up may be this fast, no faster.
    static let maxRollSpeed: Double = 150
    /// Samples further apart than this are a break (a second finger was down): calm starts over.
    static let maxGap: TimeInterval = 0.05
    /// Where a click and a Force Click start by contact size, for light, medium and firm.
    static let sizeClick: [Double] = [1.18, 1.30, 1.60]
    static let sizeForce: [Double] = [1.55, 1.70, 2.10]
    /// The report keeps this many size changes, three refused rises past that, and this many entries in
    /// all, so a long touch still shows its clicks.
    static let traceLimit = 16
    static let traceMarks = 22
    /// How slowly the resting size follows the finger, in seconds.
    static let follow: TimeInterval = 1.5
    /// A press lets go only after the finger has eased off for this long, so a wavering
    /// contact size cannot turn one press into a double click.
    static let releaseDelay: TimeInterval = 0.05

    init(pressure: Int = 1, forceEnabled: Bool = true, restFloor: Double = 0, step: Double = 0) {
        self.pressure = min(max(pressure, 0), 2)
        self.forceEnabled = forceEnabled
        self.restFloor = max(restFloor, 0)
        self.step = max(step, 0)
    }

    /// True when this touch spent most of its time as a one-step contact, pressed or not.
    var mostlySmall: Bool { smallSeconds > heldSeconds / 2 }

    /// Where a click and a Force Click start, for the current mode.
    var thresholds: (click: Double, force: Double) {
        let p = min(max(pressure, 0), 2)
        if usedRealForce {
            return ([1.8, 2.2, 2.8][p], [3.6, 4.2, 5.0][p])
        }
        // iPhones report contact size in coarse steps: one step above resting reads 1.5, two read 2
        // (see `level`), so a Force Click must sit clearly above the first step.
        return (Self.sizeClick[p], Self.sizeForce[p])
    }

    /// Medium on coarse hardware, where one step is all that separates resting from pressing.
    var needsCalmRise: Bool { pressure == 1 && step > 0 && !usedRealForce }

    /// Below this a click lets go.
    var clickRelease: Double { 1 + (thresholds.click - 1) * 0.4 }
    /// Below this a Force Click drops back to a click.
    var forceRelease: Double { let t = thresholds; return t.click + (t.force - t.click) * 0.4 }

    /// How hard the finger is pressing now: 1 is a resting touch.
    ///
    /// The size is compared with the bigger of this touch's own resting size and the usual one. A finger
    /// that lands lightly reads one coarse step small, and settling to its usual size is then a doubling:
    /// measured against the landing size alone, that read as a click and a Force Click at every setting.
    ///
    /// On coarse hardware the level counts steps above resting, half a level each, so one step is a click
    /// and two a Force Click for a small finger and a big one alike. For a fingertip resting at two steps
    /// that is the same number as the plain ratio.
    func level(radius: Double, force: Double) -> Double {
        if usedRealForce { return force }
        let rest = max(baseline, restFloor)
        guard rest > 0 else { return 1 }
        if step > 0 { return max(1 + (radius - rest) / (2 * step), 0) }
        return radius / rest
    }

    /// Feeds one sample and returns the new stage.
    @discardableResult
    mutating func update(_ s: Sample) -> Stage {
        if startTime == nil {
            startTime = s.time
            lastTime = s.time
            baseline = s.radius
            minRadius = s.radius
            maxRadius = s.radius
        }
        let age = s.time - (startTime ?? s.time)
        let dt = max(s.time - lastTime, 0)
        let previousTime = lastTime
        lastTime = s.time
        minRadius = min(minRadius, s.radius)
        maxRadius = max(maxRadius, s.radius)
        peakForce = max(peakForce, s.force)
        if s.maxForce > 0, s.force > 0 { usedRealForce = true }
        if dt > Self.maxGap { calmSince = nil }

        // Learn the resting size: the biggest size while landing, then slowly follow
        // the finger while it rests. Never while pressed.
        if age <= Self.landing {
            baseline = max(baseline, s.radius)
        } else if stage == .rest, level(radius: s.radius, force: s.force) < 1.15 {
            let k = 1 - exp(-dt / Self.follow)
            baseline += (s.radius - baseline) * k
        }

        if age > Self.landing {
            heldSeconds += dt
            if step > 0, s.radius < step * 1.5 { smallSeconds += dt }
        }

        let level = level(radius: s.radius, force: s.force)
        peakLevel = max(peakLevel, level)
        let t = thresholds
        let shownSpeed = s.speed.isFinite ? Int(min(max(s.speed, 0), 9999)) : -1
        let stamp = Int(age * 1000)
        if step > 0, s.radius != tracedRadius, trace.count < Self.traceLimit {
            tracedRadius = s.radius
            trace.append("\(stamp):\(Int((s.radius / step).rounded())):\(shownSpeed)")
        }
        switch stage {
        case .rest:
            if level >= t.click {
                if riseCalm == nil {
                    // Calm is judged up to the sample before the contact stepped up, and that sample may roll.
                    let calm = calmSince.map { previousTime - $0 >= Self.calmBefore - 0.005 } ?? false
                    let taken = calm && s.speed < Self.maxRollSpeed
                    riseCalm = taken
                    if needsCalmRise, !taken, level < Self.sizeClick[2], trace.count < Self.traceLimit + 3 {
                        trace.append("\(stamp):R:\(shownSpeed)")
                    }
                }
                calmSince = nil
                // Two steps is a press at every setting, however the finger got there.
                if age > Self.minAge, s.speed < Self.maxStartSpeed,
                   riseCalm == true || !needsCalmRise || level >= Self.sizeClick[2] {
                    stage = .click
                    riseCalm = nil
                    if step > 0, trace.count < Self.traceMarks { trace.append("\(stamp):C:\(shownSpeed)") }
                }
            } else {
                riseCalm = nil
                if s.speed < Self.stillSpeed {
                    if calmSince == nil { calmSince = s.time }
                } else {
                    calmSince = nil
                }
            }
        case .click, .force:
            if level < clickRelease {
                // Easing off counts toward calm, so a second press can follow the first closely.
                if s.speed < Self.stillSpeed {
                    if calmSince == nil { calmSince = s.time }
                } else {
                    calmSince = nil
                }
                let since = lowSince ?? s.time
                lowSince = since
                if s.time - since >= Self.releaseDelay {
                    stage = .rest
                    lowSince = nil
                }
            } else {
                calmSince = nil
                lowSince = nil
                if stage == .click {
                    if forceEnabled, level >= t.force { stage = .force }
                } else if level < forceRelease || !forceEnabled {
                    stage = .click
                }
            }
        }
        if stage.rawValue > deepest.rawValue { deepest = stage }
        return stage
    }
}

/// The size a resting fingertip has on an iPhone that reports contact in coarse steps: the floor a press
/// is measured from.
///
/// It is two steps (about 7 mm across), which is where an ordinary fingertip rests, and one step for a
/// person whose finger mostly reads that small. It is never more than two, so nothing learned here can
/// stop a press from registering, and it moves only when most recent touches agree.
struct RestingSize {
    /// How much of this person's recent touches were one-step contacts, 0 to 1.
    private(set) var smallShare: Double
    /// True while the floor is one step.
    private(set) var small: Bool

    /// A touch counts once it has lasted this long.
    static let minSeconds = 0.25
    /// How far one touch moves the share.
    static let weight = 0.1
    /// The floor drops to one step above this share and returns to two below `backBelow`.
    static let smallAbove = 0.6
    static let backBelow = 0.4

    init(smallShare: Double = 0, small: Bool = false) {
        self.smallShare = smallShare.isFinite ? min(max(smallShare, 0), 1) : 0
        self.small = small
    }

    /// The size steps this iPhone reports contact in, from `UITouch.majorRadiusTolerance` (half a step),
    /// or 0 when the size is fine grained.
    static func step(tolerance: Double) -> Double {
        tolerance.isFinite && tolerance >= 3 ? tolerance * 2 : 0
    }

    /// Takes in one finished one-finger touch.
    mutating func learn(mostlySmall: Bool, seconds: Double) {
        guard seconds.isFinite, seconds >= Self.minSeconds else { return }
        smallShare += ((mostlySmall ? 1 : 0) - smallShare) * Self.weight
        if smallShare > Self.smallAbove { small = true } else if smallShare < Self.backBelow { small = false }
    }

    /// The floor for the next touch, or 0 on fine-grained hardware, where a touch is measured against
    /// its own resting size alone.
    func floor(step: Double) -> Double {
        step > 0 ? step * (small ? 1 : 2) : 0
    }
}
