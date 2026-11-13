import UIKit
import CoreHaptics

/// The click you feel. An iPhone's glass does not move, so every click, pick-up
/// and key press is a short sharp pulse from the Taptic Engine, tuned to feel
/// like a MacBook trackpad and keyboard.
final class Haptics {
    static let shared = Haptics()

    enum Kind: CaseIterable {
        case key        // one keyboard key
        case click      // tap to click: one light tick, a Mac does not thump on a tap
        case pressDown  // a press clicks the button down
        case pressUp    // the button comes back up
        case forceDown  // the deeper second click of a Force Click
        case forceUp    // easing off from a Force Click back to a click
        case edge       // the cursor reached the edge of the Mac screen
        case swipe      // a three-finger swipe was recognized
    }

    var enabled: Bool {
        get { UserDefaults.standard.object(forKey: "haptics") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "haptics") }
    }

    private var engine: CHHapticEngine?
    private var players: [Kind: CHHapticPatternPlayer] = [:]
    private var running = false
    private let fallback = UIImpactFeedbackGenerator(style: .rigid)

    private init() {
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else { return }
        do {
            let engine = try CHHapticEngine()
            engine.playsHapticsOnly = true
            engine.isAutoShutdownEnabled = false
            engine.stoppedHandler = { [weak self] _ in
                DispatchQueue.main.async { self?.running = false }
            }
            engine.resetHandler = { [weak self] in
                DispatchQueue.main.async {
                    self?.running = false
                    self?.players.removeAll()
                    self?.start()
                }
            }
            self.engine = engine
        } catch {
            engine = nil
        }
    }

    /// Start the engine ahead of the first touch so the first click is not late.
    func start() {
        guard let engine, !running else { return }
        do {
            try engine.start()
            running = true
            if players.isEmpty { buildPlayers() }
        } catch {
            running = false
        }
    }

    func stop() {
        guard let engine, running else { return }
        engine.stop()
        running = false
    }

    func play(_ kind: Kind) {
        guard enabled else { return }
        guard engine != nil else {
            let intensity: CGFloat
            switch kind {
            case .key, .edge, .forceUp: intensity = 0.5
            case .click, .pressUp, .swipe: intensity = 0.65
            case .pressDown, .forceDown: intensity = 1
            }
            fallback.impactOccurred(intensity: intensity)
            return
        }
        if !running { start() }
        guard running, let player = players[kind] else { return }
        try? player.start(atTime: CHHapticTimeImmediate)
    }

    private func buildPlayers() {
        guard let engine else { return }
        func tap(_ intensity: Float, _ sharpness: Float, at time: TimeInterval = 0) -> CHHapticEvent {
            CHHapticEvent(eventType: .hapticTransient,
                          parameters: [CHHapticEventParameter(parameterID: .hapticIntensity, value: intensity),
                                       CHHapticEventParameter(parameterID: .hapticSharpness, value: sharpness)],
                          relativeTime: time)
        }
        let patterns: [Kind: [CHHapticEvent]] = [
            .key: [tap(0.5, 0.7)],
            .click: [tap(0.55, 0.8)],
            .pressDown: [tap(1.0, 0.75)],
            .pressUp: [tap(0.6, 0.5)],
            .forceDown: [tap(1.0, 0.45), tap(0.8, 0.3, at: 0.012)],
            .forceUp: [tap(0.5, 0.35)],
            .edge: [tap(0.3, 0.3)],
            .swipe: [tap(0.6, 0.45)],
        ]
        for (kind, events) in patterns {
            if let pattern = try? CHHapticPattern(events: events, parameters: []),
               let player = try? engine.makePlayer(with: pattern) {
                players[kind] = player
            }
        }
    }
}
