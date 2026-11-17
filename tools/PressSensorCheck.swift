import Foundation

// Checks the press sensor against the contact sizes a real foldable iPhone reports: whole steps of 12.1
// points (12.1 barely touching, 24.2 a resting fingertip, 36.3 a press, 48.4 a hard press).
// Run with tools/check-press-sensor.sh.

@main
enum PressSensorCheck {
    static let step = 12.1
    static var failures = 0

    struct Result {
        var deepest: PressSensor.Stage
        var clicks: Int
        var sensor: PressSensor
    }

    /// Plays (seconds, radius) spans at 60 samples a second.
    static func play(_ spans: [(Double, Double)], pressure: Int = 1, floor: Double, speed: Double = 0) -> Result {
        var sensor = PressSensor(pressure: pressure, forceEnabled: true, restFloor: floor, step: floor > 0 ? step : 0)
        var time = 100.0
        var clicks = 0
        for (seconds, radius) in spans {
            var left = seconds
            while left > 0 {
                let old = sensor.stage
                let new = sensor.update(.init(time: time, radius: radius, force: 0, maxForce: 0, speed: speed))
                if old == .rest, new != .rest { clicks += 1 }
                time += 1.0 / 60
                left -= 1.0 / 60
            }
        }
        return Result(deepest: sensor.deepest, clicks: clicks, sensor: sensor)
    }

    /// `ends` is the stage the touch must be in when the spans run out: a press that has eased off must have let go.
    static func expect(_ name: String, _ got: Result, deepest: PressSensor.Stage, clicks: Int, ends: PressSensor.Stage = .rest) {
        let ok = got.deepest == deepest && got.clicks == clicks && got.sensor.stage == ends
        if !ok { failures += 1 }
        print("\(ok ? "ok  " : "FAIL") \(name): deepest \(got.deepest), clicks \(got.clicks), ends \(got.sensor.stage)"
              + (ok ? "" : " (wanted \(deepest), \(clicks), \(ends))"))
    }

    static func check(_ ok: Bool, _ name: String) {
        if !ok { failures += 1 }
        print("\(ok ? "ok  " : "FAIL") \(name)")
    }

    static func learn(_ resting: inout RestingSize, _ spans: [(Double, Double)], pressure: Int = 1, speed: Double = 0) -> Result {
        let touch = play(spans, pressure: pressure, floor: resting.floor(step: step), speed: speed)
        resting.learn(mostlySmall: touch.sensor.mostlySmall, seconds: touch.sensor.heldSeconds)
        return touch
    }

    static func main() {
        let two = RestingSize().floor(step: step)
        check(abs(two - 24.2) < 0.001, "the floor starts at two steps")
        check(RestingSize().floor(step: 0) == 0, "no floor on fine-grained hardware")
        check(RestingSize.step(tolerance: 6.05) == 12.1 && RestingSize.step(tolerance: 0) == 0, "step from tolerance")

        // The fault: a finger that lands lightly, then settles to its usual size, must not click.
        for (pressure, name) in [(0, "light"), (1, "medium"), (2, "firm")] {
            expect("lands light, settles (\(name))", play([(0.3, 12.1), (1.0, 24.2)], pressure: pressure, floor: two), deepest: .rest, clicks: 0)
            expect("glides light 2 s, then rests (\(name))", play([(0.2, 24.2), (2.0, 12.1), (1.0, 24.2)], pressure: pressure, floor: two), deepest: .rest, clicks: 0)
        }
        // With no floor (the sensor as it shipped in 1.0) the same touches click and stay down, with a Force Click on medium.
        expect("1.0 behaviour: lands light, settles (medium)", play([(0.3, 12.1), (1.0, 24.2)], floor: 0), deepest: .force, clicks: 1, ends: .force)
        expect("1.0 behaviour: lands light, settles (firm)", play([(0.3, 12.1), (1.0, 24.2)], pressure: 2, floor: 0), deepest: .click, clicks: 1, ends: .click)
        expect("1.0 behaviour: glides light, then rests (medium)", play([(0.2, 24.2), (2.0, 12.1), (1.0, 24.2)], floor: 0), deepest: .click, clicks: 1, ends: .click)

        // Real presses still work, and let go.
        expect("press one step (light)", play([(0.4, 24.2), (0.3, 36.3), (0.3, 24.2)], pressure: 0, floor: two), deepest: .click, clicks: 1)
        expect("press one step (medium)", play([(0.4, 24.2), (0.3, 36.3), (0.3, 24.2)], floor: two), deepest: .click, clicks: 1)
        expect("press one step (firm) is not enough", play([(0.4, 24.2), (0.3, 36.3), (0.3, 24.2)], pressure: 2, floor: two), deepest: .rest, clicks: 0)
        expect("press two steps (firm)", play([(0.4, 24.2), (0.3, 48.4), (0.3, 24.2)], pressure: 2, floor: two), deepest: .click, clicks: 1)
        expect("press two steps (medium) is a Force Click", play([(0.4, 24.2), (0.2, 36.3), (0.3, 48.4), (0.3, 24.2)], floor: two), deepest: .force, clicks: 1)
        expect("lands light, then presses (medium)", play([(0.3, 12.1), (0.3, 24.2), (0.3, 36.3), (0.3, 24.2)], floor: two), deepest: .click, clicks: 1)
        expect("lands light, jumps to a press (medium): a click, not a Force Click", play([(0.3, 12.1), (0.3, 36.3)], floor: two), deepest: .click, clicks: 1, ends: .click)
        expect("a press held, then eased back to a light touch, lets go", play([(0.4, 24.2), (1.0, 36.3), (0.3, 12.1)], floor: two), deepest: .click, clicks: 1)
        expect("two presses in one touch (medium)", play([(0.4, 24.2), (0.2, 36.3), (0.3, 24.2), (0.2, 36.3), (0.3, 24.2)], floor: two), deepest: .click, clicks: 2)
        expect("a press while gliding fast does not start", play([(0.4, 24.2), (0.3, 36.3)], floor: two, speed: 400), deepest: .rest, clicks: 0)
        expect("a big resting finger presses from its own size", play([(0.4, 36.3), (0.3, 48.4), (0.3, 36.3)], floor: two), deepest: .click, clicks: 1)
        expect("a big landing that relaxed for 2.5 s: one step up clicks", play([(0.4, 36.3), (2.5, 24.2), (0.3, 36.3), (0.3, 24.2)], floor: two), deepest: .click, clicks: 1)

        // The floor never goes above two steps, whatever is learned: big contacts, long firm presses, fast glides.
        var big = RestingSize()
        for radius in [48.4, 48.4, 48.4, 60.5, 60.5, 60.5, 80, 80] { _ = learn(&big, [(1.0, radius)]) }
        for _ in 0..<60 { _ = learn(&big, [(0.35, 24.2), (0.5, 36.3), (0.4, 48.4), (0.2, 24.2)], pressure: 2) }
        for _ in 0..<60 { _ = learn(&big, [(1.0, 36.3)], speed: 400) }
        check(abs(big.floor(step: step) - 24.2) < 0.001, "after big contacts, firm presses and fast glides the floor is still two steps")
        expect("and an ordinary press still clicks (medium)", play([(0.4, 24.2), (0.3, 36.3), (0.3, 24.2)], floor: big.floor(step: step)), deepest: .click, clicks: 1)
        expect("and a firm press still clicks (firm)", play([(0.35, 24.2), (0.5, 36.3), (0.4, 48.4), (0.2, 24.2)], pressure: 2, floor: big.floor(step: step)), deepest: .click, clicks: 1)

        // An ordinary finger: one whole-touch-light glide in five never moves the floor.
        var usual = RestingSize()
        var moved = false
        for index in 0..<300 {
            _ = learn(&usual, [(0.6, index % 5 == 0 ? 12.1 : 24.2)])
            if usual.small { moved = true }
        }
        check(!moved, "one light glide in five never drops the floor (share \(String(format: "%.2f", usual.smallShare)))")
        // A light landing that settles is not a small touch: it is mostly two steps.
        for _ in 0..<30 { _ = learn(&usual, [(0.2, 12.1), (0.6, 24.2)]) }
        check(!usual.small, "light landings that settle do not drop the floor")
        // A run of whole-touch-light glides does drop it after a while, and ordinary touches bring it back,
        // including the touches that then click by mistake (they are mostly two steps).
        var run = 0
        while !usual.small, run < 50 { _ = learn(&usual, [(0.6, 12.1)]); run += 1 }
        print("     a run of \(run) light glides drops the floor to one step")
        check(run >= 7, "it takes a long run")
        var back = 0
        while usual.small, back < 50 { _ = learn(&usual, [(0.2, 12.1), (0.8, 24.2)]); back += 1 }
        print("     \(back) ordinary touches bring it back")
        check(back <= 6, "it comes back quickly")

        // A person whose finger always reads one step gets a one-step floor, and then clicks with one step more.
        var small = RestingSize()
        var touches = 0
        while !small.small, touches < 50 { _ = learn(&small, [(1.0, 12.1)]); touches += 1 }
        print("     a one-step finger is learned after \(touches) touches")
        check(touches <= 10, "a one-step finger is learned soon")
        expect("one-step finger presses to two steps (medium)", play([(0.4, 12.1), (0.3, 24.2), (0.3, 12.1)], floor: small.floor(step: step)), deepest: .click, clicks: 1)
        expect("one-step finger presses to three steps (medium) is a Force Click", play([(0.4, 12.1), (0.2, 24.2), (0.3, 36.3), (0.3, 12.1)], floor: small.floor(step: step)), deepest: .force, clicks: 1)
        for _ in 0..<40 { _ = learn(&small, [(0.4, 12.1), (0.3, 24.2), (0.3, 12.1)]) }
        check(small.small, "a one-step finger that keeps clicking keeps its one-step floor")

        // Short touches and bad values teach nothing.
        var steady = RestingSize(smallShare: 0.3, small: false)
        steady.learn(mostlySmall: true, seconds: 0.1)
        steady.learn(mostlySmall: true, seconds: .nan)
        check(steady.smallShare == 0.3, "short and bad touches teach nothing")
        check(RestingSize(smallShare: .nan).smallShare == 0 && RestingSize(smallShare: 7).smallShare == 1, "a bad saved share is cleaned")

        print(failures == 0 ? "all checks passed" : "\(failures) check(s) failed")
        exit(failures == 0 ? 0 : 1)
    }
}
