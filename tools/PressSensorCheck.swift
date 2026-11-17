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

    /// Plays (seconds, radius) spans at 60 samples a second, all at one finger speed.
    static func play(_ spans: [(Double, Double)], pressure: Int = 1, floor: Double, speed: Double = 0) -> Result {
        move(spans.map { ($0.0, $0.1, speed) }, pressure: pressure, floor: floor)
    }

    /// Plays (seconds, radius, finger speed) spans at 60 samples a second. A negative radius is a stretch
    /// with no samples, as when a second finger is down.
    static func move(_ spans: [(Double, Double, Double)], pressure: Int = 1, floor: Double) -> Result {
        var sensor = PressSensor(pressure: pressure, forceEnabled: true, restFloor: floor, step: floor > 0 ? step : 0)
        var time = 100.0
        var clicks = 0
        for (seconds, radius, speed) in spans {
            if radius < 0 { time += seconds; continue }
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

        // Medium on coarse hardware: one step bigger is a press only if it stepped up while the finger was still.
        // A fingertip flattens to the same size during a glide, and that must not click.
        expect("flattens during a fast glide, then slows to a stop (medium)",
               move([(0.2, 24.2, 0), (0.4, 36.3, 600), (0.2, 36.3, 150), (0.8, 36.3, 0)], floor: two), deepest: .rest, clicks: 0)
        expect("flattens during a slow glide (medium)",
               move([(0.2, 24.2, 0), (0.3, 24.2, 150), (0.6, 36.3, 150), (0.3, 24.2, 150)], floor: two), deepest: .rest, clicks: 0)
        expect("stops, and flattens in the same moment (medium)",
               move([(0.3, 24.2, 300), (0.05, 24.2, 0), (0.5, 36.3, 0)], floor: two), deepest: .rest, clicks: 0)
        expect("stops, then presses (medium)",
               move([(0.3, 24.2, 300), (0.2, 24.2, 0), (0.3, 36.3, 0), (0.3, 24.2, 0)], floor: two), deepest: .click, clicks: 1)
        expect("presses with the roll a pressing fingertip makes (medium)",
               move([(0.3, 24.2, 10), (0.02, 36.3, 120), (0.25, 36.3, 40), (0.3, 24.2, 20)], floor: two), deepest: .click, clicks: 1)
        expect("still, then sets off fast and flattens on the way, then stops (medium)",
               move([(0.3, 24.2, 0), (0.4, 36.3, 300), (0.5, 36.3, 0), (0.2, 24.2, 0)], floor: two), deepest: .rest, clicks: 0)
        expect("presses, then drags fast with the button down (medium)",
               move([(0.3, 24.2, 0), (0.1, 36.3, 0), (0.8, 36.3, 700), (0.3, 24.2, 0)], floor: two), deepest: .click, clicks: 1)
        expect("after a glide that flattened: relax, stop, press (medium)",
               move([(0.2, 24.2, 0), (0.5, 36.3, 600), (0.3, 24.2, 0), (0.3, 36.3, 0), (0.3, 24.2, 0)], floor: two), deepest: .click, clicks: 1)
        expect("presses a tenth of a second after landing (medium)",
               move([(0.1, 24.2, 0), (0.3, 36.3, 0), (0.2, 24.2, 0)], floor: two), deepest: .click, clicks: 1)
        expect("presses twice with a tenth of a second between (medium)",
               move([(0.3, 24.2, 0), (0.12, 36.3, 0), (0.1, 24.2, 0), (0.15, 36.3, 0), (0.2, 24.2, 0)], floor: two), deepest: .click, clicks: 2)
        expect("presses twice with a tenth of a second between (light)",
               move([(0.3, 24.2, 0), (0.12, 36.3, 0), (0.1, 24.2, 0), (0.15, 36.3, 0), (0.2, 24.2, 0)], pressure: 0, floor: two), deepest: .click, clicks: 2)
        expect("two steps during a slow glide is a press (medium)",
               move([(0.2, 24.2, 0), (0.3, 24.2, 150), (0.3, 48.4, 150), (0.3, 24.2, 150)], floor: two), deepest: .force, clicks: 1)
        expect("rests, a second finger comes and goes, and it is bigger when sampling resumes (medium)",
               move([(0.2, 24.2, 0), (1.0, -1, 0), (0.4, 36.3, 100), (0.3, 36.3, 0), (0.2, 24.2, 0)], floor: two), deepest: .rest, clicks: 0)
        expect("after a second finger: relax, stop, press (medium)",
               move([(0.2, 24.2, 0), (1.0, -1, 0), (0.2, 36.3, 100), (0.2, 24.2, 0), (0.2, 36.3, 0), (0.2, 24.2, 0)], floor: two), deepest: .click, clicks: 1)
        // Light keeps the eager rule, and Firm its two steps, glide or not.
        expect("flattens during a slow glide (light) still clicks",
               move([(0.2, 24.2, 0), (0.3, 24.2, 150), (0.3, 36.3, 150), (0.3, 24.2, 150)], pressure: 0, floor: two), deepest: .click, clicks: 1)
        expect("flattens during a slow glide (firm)",
               move([(0.2, 24.2, 0), (0.3, 24.2, 150), (0.3, 36.3, 150), (0.3, 24.2, 150)], pressure: 2, floor: two), deepest: .rest, clicks: 0)
        expect("two steps during a slow glide (firm) clicks",
               move([(0.2, 24.2, 0), (0.3, 24.2, 150), (0.3, 48.4, 150), (0.3, 24.2, 150)], pressure: 2, floor: two), deepest: .click, clicks: 1)
        let traced = move([(0.3, 24.2, 0), (0.2, 36.3, 0), (0.2, 24.2, 0)], floor: two).sensor.trace
        check(traced.count == 4 && traced[0] == "0:2:0" && traced[2].hasSuffix(":C:0") && traced[3].hasSuffix(":2:0"),
              "the trace lists size changes and the click: \(traced.joined(separator: " "))")
        let refused = move([(0.2, 24.2, 0), (0.3, 24.2, 200), (0.3, 36.3, 200)], floor: two).sensor.trace
        check(refused.filter { $0.hasSuffix(":R:200") }.count == 1, "a refused rise is marked once: \(refused.joined(separator: " "))")
        var flicker: [(Double, Double, Double)] = []
        for _ in 0..<40 { flicker += [(0.1, 24.2, 300), (0.1, 36.3, 300)] }
        let long = move(flicker + [(0.3, 24.2, 0), (0.2, 36.3, 0)], floor: two).sensor.trace
        check(long.count <= PressSensor.traceMarks && long.last?.contains(":C:") == true && long.joined(separator: " ").utf8.count < 320,
              "a long trace is capped and still ends with the click: \(long.count) entries, \(long.joined(separator: " ").utf8.count) bytes")
        var wild = PressSensor(pressure: 1, restFloor: two, step: step)
        wild.update(.init(time: 1, radius: 24.2, force: 0, maxForce: 0, speed: .nan))
        wild.update(.init(time: 1.2, radius: 36.3, force: 0, maxForce: 0, speed: .infinity))
        check(wild.stage == .rest, "a speed that is not a number does not crash or click")

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
