import UIKit

/// A Mac-style trackpad. One finger moves, tap clicks, press clicks and presses deeper
/// for a Force Click, two-finger tap right-clicks, two fingers scroll, three fingers
/// swipe between spaces. With Press to click off, hold still then move drags.
final class TrackpadView: UIView {
    var send: (([InputEvent]) -> Void)?
    /// Called after a click so a latched modifier (for example Command) is used up.
    var onClick: (() -> Void)?
    /// One line about each touch for the Mac's log, to tune the press.
    var report: ((String) -> Void)?

    private var active = Set<UITouch>()
    private var startTime: TimeInterval = 0
    private var maxCount = 0
    private var moved = false
    private var dragging = false        // the hold-still drag (Press to click off)
    private var anchor = CGPoint.zero   // where the fingers were when the finger count last changed
    private var slop: CGFloat = 8
    private var lastCentroid = CGPoint.zero
    private var lastMoveTime: TimeInterval = 0
    private var holdTimer: Timer?
    private var scrollVelocity = CGPoint.zero
    private var momentum: CADisplayLink?
    private var lastMomentumTime: CFTimeInterval = 0
    private var swipe = CGPoint.zero
    private var swipeFired = false
    /// True while a finger is on the trackpad.
    var isTouching: Bool { !active.isEmpty }

    // Settings, read when a touch starts.
    private var tapToClick = true
    private var pressToClick = true
    private var forceClick = true
    private var clickPressure = 1

    // Press to click.
    private var sensor = PressSensor()
    private var pressTouch: UITouch?
    private var pressLink: CADisplayLink?
    private var lastPressPoint = CGPoint.zero
    private var lastPressTime: TimeInterval = 0
    private var pressSpeed: Double = 0
    private var pressed = false         // the button is down from a press
    private var pressedThisTouch = false
    private var forceSent = false
    private var pressPoint = CGPoint.zero
    private var dragArmed = false
    private var quietUntil: TimeInterval = 0
    private var radiusTolerance: CGFloat = 0
    private var maxForce: CGFloat = 0

    // Click counting, so a double click never depends on the Mac's own distance check.
    private var clicks: UInt8 = 0       // count of the click in progress or the last one
    private var lastClickEnd: TimeInterval = -10
    private var lastClickButton: UInt8 = 0
    private var movedSinceClick = true
    private var touchClicks: UInt8 = 0  // for the report
    private var tapped = false
    private var lastReportTime: TimeInterval = 0

    /// Clicks this close together count as a double or triple click.
    private static let multiClickWindow: TimeInterval = 0.45

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        backgroundColor = UIColor(red: 0.220, green: 0.215, blue: 0.232, alpha: 1)
        layer.cornerRadius = 14
        layer.cornerCurve = .continuous
        layer.borderWidth = 1
        layer.borderColor = UIColor(white: 0, alpha: 0.55).cgColor
        isAccessibilityElement = true
        accessibilityLabel = "Trackpad"
        accessibilityIdentifier = "trackpad"
        accessibilityTraits = .allowsDirectInteraction
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func centroid() -> CGPoint {
        guard !active.isEmpty else { return .zero }
        var x: CGFloat = 0, y: CGFloat = 0
        for t in active {
            let p = t.location(in: self)
            x += p.x
            y += p.y
        }
        return CGPoint(x: x / CGFloat(active.count), y: y / CGFloat(active.count))
    }

    private func readSettings() {
        // bool(forKey:) also reads "NO" from launch arguments, which `as? Bool` does not.
        let d = UserDefaults.standard
        func flag(_ key: String) -> Bool { d.object(forKey: key) == nil ? true : d.bool(forKey: key) }
        tapToClick = flag("tapToClick")
        pressToClick = flag("pressToClick")
        forceClick = flag("forceClick")
        clickPressure = d.object(forKey: "clickPressure") == nil ? 1 : min(max(d.integer(forKey: "clickPressure"), 0), 2)
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        stopMomentum()
        let now = ProcessInfo.processInfo.systemUptime
        if active.isEmpty {
            readSettings()
            startTime = now
            maxCount = 0
            moved = false
            swipe = .zero
            swipeFired = false
            scrollVelocity = .zero
            tapped = false
            touchClicks = 0
            // Right after a click the finger lands less precisely: allow more wobble for a double tap.
            slop = now - lastClickEnd < Self.multiClickWindow ? 16 : 8
            startPress(touches.first, now: now)
            holdTimer?.invalidate()
            holdTimer = nil
            if !pressToClick {
                let timer = Timer(timeInterval: 0.32, repeats: false) { [weak self] _ in self?.holdFired() }
                RunLoop.main.add(timer, forMode: .common)
                holdTimer = timer
            }
        }
        active.formUnion(touches)
        maxCount = max(maxCount, active.count)
        if active.count > 1 { cancelHold() }
        lastCentroid = centroid()
        anchor = lastCentroid
        lastMoveTime = now
        samplePress(now: now)
    }

    private func holdFired() {
        holdTimer = nil
        guard active.count == 1, !moved, !dragging else { return }
        dragging = true
        Haptics.shared.play(.pressDown)
        clicks = nextClickCount(button: 0, startingAt: startTime)
        touchClicks = clicks
        send?([.button(index: 0, down: true, clicks: clicks)])
    }

    private func cancelHold() {
        holdTimer?.invalidate()
        holdTimer = nil
    }

    /// The count for a click starting now: one more than the last click when it is
    /// quick, on the same button, and the pointer has not moved since.
    private func nextClickCount(button: UInt8, startingAt time: TimeInterval) -> UInt8 {
        if time - lastClickEnd < Self.multiClickWindow, button == lastClickButton, !movedSinceClick {
            return min(clicks + 1, 3)
        }
        return 1
    }

    private func clickEnded(button: UInt8, at time: TimeInterval) {
        lastClickEnd = time
        lastClickButton = button
        movedSinceClick = false
    }

    private func movePointer(_ delta: CGPoint, dt: TimeInterval) {
        let speed = hypot(delta.x, delta.y) / CGFloat(dt)
        let gain = TrackpadView.gain(forSpeed: speed)
        send?([.moveRel(dx: Float(delta.x * gain), dy: Float(delta.y * gain))])
        if delta != .zero { movedSinceClick = true }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        let now = ProcessInfo.processInfo.systemUptime
        let c = centroid()
        let delta = CGPoint(x: c.x - lastCentroid.x, y: c.y - lastCentroid.y)
        let dt = max(now - lastMoveTime, 0.004)
        lastCentroid = c
        lastMoveTime = now
        samplePress(now: now)
        // Moved means the fingers left the spot they landed on, not that they wobbled.
        if !moved, hypot(c.x - anchor.x, c.y - anchor.y) > slop {
            moved = true
            if !dragging { cancelHold() }
        }

        switch active.count {
        case 1:
            if pressed {
                // Pressing flattens the fingertip and shifts the touch point: that is not a drag.
                guard now >= quietUntil else { return }
                if !dragArmed {
                    guard hypot(c.x - pressPoint.x, c.y - pressPoint.y) >= 4 else { return }
                    dragArmed = true
                }
            } else {
                guard moved || dragging, now >= quietUntil else { return }
            }
            movePointer(delta, dt: dt)
        case 2:
            guard moved else { return }
            let k: CGFloat = 1.7
            send?([.scroll(dx: Float(delta.x * k), dy: Float(delta.y * k))])
            let v = CGPoint(x: delta.x * k / CGFloat(dt), y: delta.y * k / CGFloat(dt))
            scrollVelocity = CGPoint(x: scrollVelocity.x * 0.6 + v.x * 0.4, y: scrollVelocity.y * 0.6 + v.y * 0.4)
        default:
            guard moved else { return }
            swipe.x += delta.x
            swipe.y += delta.y
            if !swipeFired, max(abs(swipe.x), abs(swipe.y)) > 55 {
                swipeFired = true
                fireSwipe()
            }
        }
    }

    // MARK: Press to click

    private func startPress(_ touch: UITouch?, now: TimeInterval) {
        sensor = PressSensor(pressure: clickPressure, forceEnabled: forceClick)
        pressTouch = touch
        pressed = false
        pressedThisTouch = false
        forceSent = false
        dragArmed = false
        pressSpeed = 0
        lastPressTime = now
        lastPressPoint = touch?.location(in: self) ?? .zero
        radiusTolerance = touch?.majorRadiusTolerance ?? 0
        maxForce = touch?.maximumPossibleForce ?? 0
        // The size of the contact can change without the finger moving, so also look every frame.
        pressLink?.invalidate()
        let link = CADisplayLink(target: self, selector: #selector(pressTick))
        link.add(to: .main, forMode: .common)
        pressLink = link
    }

    @objc private func pressTick() {
        samplePress(now: ProcessInfo.processInfo.systemUptime)
    }

    private func stopPressLink() {
        pressLink?.invalidate()
        pressLink = nil
    }

    /// Feeds the one finger on the pad to the sensor. Always measured, for the report;
    /// only acted on when Press to click is on.
    private func samplePress(now: TimeInterval) {
        guard active.count == 1, let touch = pressTouch, active.contains(touch) else { return }
        let p = touch.location(in: self)
        let dt = now - lastPressTime
        if dt > 0.001 {
            let speed = Double(hypot(p.x - lastPressPoint.x, p.y - lastPressPoint.y)) / dt
            pressSpeed = pressSpeed * 0.5 + speed * 0.5
            lastPressPoint = p
            lastPressTime = now
        }
        maxForce = max(maxForce, touch.maximumPossibleForce)
        let old = sensor.stage
        let new = sensor.update(.init(time: now, radius: Double(touch.majorRadius), force: Double(touch.force),
                                      maxForce: Double(touch.maximumPossibleForce), speed: pressSpeed))
        guard pressToClick, new != old else { return }
        changeStage(from: old, to: new, at: p, now: now)
    }

    private func changeStage(from old: PressSensor.Stage, to new: PressSensor.Stage, at point: CGPoint, now: TimeInterval) {
        quietUntil = now + 0.06
        switch (old, new) {
        case (.rest, _):
            pressed = true
            pressedThisTouch = true
            pressPoint = point
            dragArmed = false
            Haptics.shared.play(.pressDown)
            clicks = nextClickCount(button: 0, startingAt: now)
            touchClicks = clicks
            send?([.button(index: 0, down: true, clicks: clicks)])
        case (.click, .force):
            Haptics.shared.play(.forceDown)
            if !forceSent {
                forceSent = true
                send?([.action(HostAction.forceClick.rawValue)])
            }
        case (.force, .click):
            Haptics.shared.play(.forceUp)
        case (_, .rest):
            releasePress(now: now)
        default:
            break
        }
    }

    private func releasePress(now: TimeInterval) {
        guard pressed else { return }
        pressed = false
        Haptics.shared.play(.pressUp)
        send?([.button(index: 0, down: false, clicks: clicks)])
        clickEnded(button: 0, at: now)
        onClick?()
    }

    // MARK: Gestures

    /// Slow movement is precise, fast movement crosses the whole Mac screen.
    private static func gain(forSpeed speed: CGFloat) -> CGFloat {
        let t = min(max((speed - 70) / 900, 0), 1)
        let eased = t * t * (3 - 2 * t)
        return 1.25 + 3.0 * eased
    }

    private func fireSwipe() {
        Haptics.shared.play(.swipe)
        func combo(_ key: UInt16) -> [InputEvent] {
            [.key(code: 59, down: true, isRepeat: false), .key(code: key, down: true, isRepeat: false),
             .key(code: key, down: false, isRepeat: false), .key(code: 59, down: false, isRepeat: false)]
        }
        if abs(swipe.x) > abs(swipe.y) {
            // Content follows the fingers: swiping left shows the space on the right.
            send?(combo(swipe.x < 0 ? 124 : 123))
        } else if swipe.y < 0 {
            send?([.action(HostAction.missionControl.rawValue)])
        } else {
            send?(combo(125))
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        finish(touches, cancelled: false)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        finish(touches, cancelled: true)
    }

    private func finish(_ touches: Set<UITouch>, cancelled: Bool) {
        active.subtract(touches)
        let now = ProcessInfo.processInfo.systemUptime
        // The pressing finger lifted: the button comes up even if other fingers stay.
        if let t = pressTouch, touches.contains(t) {
            pressTouch = nil
            releasePress(now: now)
        }
        guard active.isEmpty else {
            lastCentroid = centroid()
            anchor = lastCentroid
            lastMoveTime = now
            return
        }
        cancelHold()
        stopPressLink()
        if dragging {
            dragging = false
            Haptics.shared.play(.pressUp)
            send?([.button(index: 0, down: false, clicks: clicks)])
            clickEnded(button: 0, at: now)
            onClick?()
        } else if !cancelled, !moved, !pressedThisTouch, now - startTime < 0.35 {
            if tapToClick {
                let button: UInt8 = maxCount >= 3 ? 2 : (maxCount == 2 ? 1 : 0)
                // A tap that is not on the same button never continues a double click.
                clicks = nextClickCount(button: button, startingAt: startTime)
                tapped = true
                touchClicks = clicks
                Haptics.shared.play(.click)
                send?([.button(index: button, down: true, clicks: clicks), .button(index: button, down: false, clicks: clicks)])
                clickEnded(button: button, at: now)
                onClick?()
            }
        } else if !cancelled, maxCount == 2, now - lastMoveTime < 0.06, hypot(scrollVelocity.x, scrollVelocity.y) > 180 {
            startMomentum()
        }
        sendReport(now: now)
    }

    /// At most one line a second, so a burst of taps does not flood the log.
    private func sendReport(now: TimeInterval) {
        guard let report, now - lastReportTime >= 1 else { return }
        lastReportTime = now
        let s = sensor
        let text = String(format: "pad: fingers %ld, %.2fs, radius base %.1f min %.1f max %.1f tol %.1f, force %.1f of %.1f, peak %.2f, stage %ld, tap %ld, n %ld",
                          maxCount, now - startTime, s.baseline, s.minRadius, s.maxRadius, Double(radiusTolerance),
                          s.peakForce, Double(maxForce), s.peakLevel, s.deepest.rawValue, tapped ? 1 : 0, Int(touchClicks))
        report(text)
    }

    // MARK: Scroll momentum

    private func startMomentum() {
        stopMomentum()
        lastMomentumTime = CACurrentMediaTime()
        let link = CADisplayLink(target: self, selector: #selector(momentumTick))
        link.add(to: .main, forMode: .common)
        momentum = link
    }

    private func stopMomentum() {
        momentum?.invalidate()
        momentum = nil
    }

    @objc private func momentumTick() {
        let now = CACurrentMediaTime()
        let dt = CGFloat(min(now - lastMomentumTime, 0.05))
        lastMomentumTime = now
        let decay = pow(0.04, dt) // loses 96% of its speed each second
        scrollVelocity = CGPoint(x: scrollVelocity.x * decay, y: scrollVelocity.y * decay)
        if hypot(scrollVelocity.x, scrollVelocity.y) < 30 {
            stopMomentum()
            return
        }
        send?([.scroll(dx: Float(scrollVelocity.x * dt), dy: Float(scrollVelocity.y * dt))])
    }
}
