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

    private(set) var stage: Stage = .rest
    private(set) var baseline: Double = 0
    private(set) var minRadius: Double = 0
    private(set) var maxRadius: Double = 0
    private(set) var peakLevel: Double = 0
    private(set) var peakForce: Double = 0
    private(set) var usedRealForce = false
    /// The deepest stage this touch reached.
    private(set) var deepest: Stage = .rest

    private var startTime: TimeInterval?
    private var lastTime: TimeInterval = 0
    private var lowSince: TimeInterval?

    /// The finger is still landing for this long; its size then is its resting size.
    static let landing: TimeInterval = 0.07
    /// A press cannot start this early, so a quick tap never clicks twice.
    static let minAge: TimeInterval = 0.09
    /// A press cannot start while the finger is gliding this fast.
    static let maxStartSpeed: Double = 250
    /// How slowly the resting size follows the finger, in seconds.
    static let follow: TimeInterval = 1.5
    /// A press lets go only after the finger has eased off for this long, so a wavering
    /// contact size cannot turn one press into a double click.
    static let releaseDelay: TimeInterval = 0.05

    init(pressure: Int = 1, forceEnabled: Bool = true) {
        self.pressure = min(max(pressure, 0), 2)
        self.forceEnabled = forceEnabled
    }

    /// Where a click and a Force Click start, for the current mode.
    var thresholds: (click: Double, force: Double) {
        let p = min(max(pressure, 0), 2)
        if usedRealForce {
            return ([1.8, 2.2, 2.8][p], [3.6, 4.2, 5.0][p])
        }
        // Older iPhones report contact size in coarse steps (a press reads 1.5x, then 2x),
        // so a Force Click must sit clearly above the first step.
        return ([1.18, 1.30, 1.60][p], [1.55, 1.70, 2.10][p])
    }

    /// Below this a click lets go.
    var clickRelease: Double { 1 + (thresholds.click - 1) * 0.4 }
    /// Below this a Force Click drops back to a click.
    var forceRelease: Double { let t = thresholds; return t.click + (t.force - t.click) * 0.4 }

    /// How hard the finger is pressing now: 1 is a resting touch.
    func level(radius: Double, force: Double) -> Double {
        if usedRealForce { return force }
        guard baseline > 0 else { return 1 }
        return radius / baseline
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
        lastTime = s.time
        minRadius = min(minRadius, s.radius)
        maxRadius = max(maxRadius, s.radius)
        peakForce = max(peakForce, s.force)
        if s.maxForce > 0, s.force > 0 { usedRealForce = true }

        // Learn the resting size: the biggest size while landing, then slowly follow
        // the finger while it rests. Never while pressed.
        if age <= Self.landing {
            baseline = max(baseline, s.radius)
        } else if stage == .rest, level(radius: s.radius, force: s.force) < 1.15 {
            let k = 1 - exp(-dt / Self.follow)
            baseline += (s.radius - baseline) * k
        }

        let level = level(radius: s.radius, force: s.force)
        peakLevel = max(peakLevel, level)
        let t = thresholds
        switch stage {
        case .rest:
            if age > Self.minAge, s.speed < Self.maxStartSpeed, level >= t.click { stage = .click }
        case .click, .force:
            if level < clickRelease {
                let since = lowSince ?? s.time
                lowSince = since
                if s.time - since >= Self.releaseDelay {
                    stage = .rest
                    lowSince = nil
                }
            } else {
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
