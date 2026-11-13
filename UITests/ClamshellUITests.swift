import XCTest

/// Drives the real keyboard and trackpad with real touches against a Mac host
/// running in test mode (`--test-pattern --dry-run`), which logs what it received.
/// Set TEST_RUNNER_HOST_LOG to the host's log file to check what the Mac saw.
final class ClamshellUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
    }

    /// Launches the app paired with the test host. Never finds a real Mac on the network.
    private func launch(_ extra: [String] = []) {
        let link = ProcessInfo.processInfo.environment["PAIRING_URL"] ?? ""
        XCTAssertFalse(link.isEmpty, "Set TEST_RUNNER_PAIRING_URL to the host's pairing link")
        app = XCUIApplication()
        // The iPhone keyboard is the default; these tests drive the Mac keyboard unless they ask otherwise.
        let style = extra.contains("-keyboardStyle") ? [] : ["-keyboardStyle", "mac"]
        app.launchArguments = ["-pairingURL", link, "-noBonjour", "YES"] + style + extra
        if let hinge = ProcessInfo.processInfo.environment["FORCE_HINGE"] {
            app.launchArguments += ["-forceHinge", hinge]
        }
        app.launch()
    }

    /// Launches the app with no pairing link and without the test host (the demo, the pairing screen).
    private func launchUnpaired(_ extra: [String]) {
        app = XCUIApplication()
        app.launchArguments = ["-noBonjour", "YES"] + extra
        if let hinge = ProcessInfo.processInfo.environment["FORCE_HINGE"] {
            app.launchArguments += ["-forceHinge", hinge]
        }
        app.launch()
    }

    private func key(_ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id]
    }

    private func hostLog() -> String {
        guard let path = ProcessInfo.processInfo.environment["HOST_LOG"],
              let data = FileManager.default.contents(atPath: path) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    /// Waits for the host to log `text` after the first `offset` characters of its log.
    private func hostSaw(_ text: String, after offset: Int, timeout: TimeInterval = 5) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        repeat {
            let log = hostLog()
            if log.count > offset, log.dropFirst(offset).contains(text) { return true }
            Thread.sleep(forTimeInterval: 0.2)
        } while Date() < end
        return false
    }

    func testKeyboardAndTrackpad() {
        launch()
        let trackpad = key("trackpad")
        XCTAssertTrue(trackpad.waitForExistence(timeout: 10))
        sleep(3) // let the stream come up

        // Typing: h, i
        key("key-4").tap()
        key("key-34").tap()
        // Latched Command, then C: the Mac must see Command held for that one key only.
        key("mod-55").tap()
        key("key-8").tap()
        key("key-0").tap()
        // Shift held with one finger while another key is pressed is covered by the latch path;
        // fn layer: fn then the left arrow becomes Home (115).
        key("key-fn").tap()
        key("key-123").tap()
        // Media row: volume up (12th key) sends a media key, with fn it sends F12 (111).
        key("fkey-12").tap()
        key("key-fn").tap()
        key("fkey-12").tap()

        // Trackpad: click, right click, move.
        trackpad.tap()
        trackpad.twoFingerTap()
        let start = trackpad.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5))
        let end = trackpad.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.6))
        start.press(forDuration: 0.05, thenDragTo: end)
        sleep(1)

        // Double tap: the Mac must see a click count of 2, counted on the phone.
        XCTAssertNotNil(ProcessInfo.processInfo.environment["HOST_LOG"], "Set TEST_RUNNER_HOST_LOG to the host's log file")
        let before = hostLog().count
        trackpad.doubleTap()
        XCTAssertTrue(hostSaw("input: button 0 down x2", after: before), "The Mac did not see a double click")
        XCTAssertTrue(hostSaw("input: button 0 up x2", after: before), "The double click's release lost its count")

        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// Characters the host was asked to type after `offset`, from its `input: text N chars` lines.
    private func typedCount(after offset: Int) -> Int {
        let log = hostLog()
        guard log.count > offset else { return 0 }
        var total = 0
        for line in log.dropFirst(offset).split(separator: "\n") {
            guard let range = line.range(of: "input: text ") else { continue }
            let rest = line[range.upperBound...]
            total += Int(rest.prefix { $0.isNumber }) ?? 0
        }
        return total
    }

    /// The iOS keyboard mode: real typing goes to the Mac as text, the bar sends keys,
    /// a latched Command turns the next character into a shortcut, and the Mac keyboard comes back.
    func testIPhoneKeyboard() {
        launch(["-keyboardStyle", "iphone"])
        XCTAssertNotNil(ProcessInfo.processInfo.environment["HOST_LOG"], "Set TEST_RUNNER_HOST_LOG to the host's log file")
        let trackpad = key("trackpad")
        // The first time, iOS puts a swipe-typing tip over its keyboard.
        let tip = app.buttons["Continue"]
        if tip.waitForExistence(timeout: 8) { tip.tap() }
        let systemKeyboard = app.keyboards.element
        XCTAssertTrue(systemKeyboard.waitForExistence(timeout: 15), "The iOS keyboard did not come up")
        XCTAssertTrue(key("bar-esc").waitForExistence(timeout: 5), "The modifier bar is missing")
        XCTAssertFalse(key("key-4").exists, "The Mac keyboard should be hidden")
        sleep(2)
        var before = hostLog().count
        app.typeText("hello world")
        let end = Date().addingTimeInterval(5)
        while typedCount(after: before) < 11, Date() < end { Thread.sleep(forTimeInterval: 0.2) }
        XCTAssertGreaterThanOrEqual(typedCount(after: before), 11, "The Mac did not get the typed text")

        before = hostLog().count
        key("bar-esc").tap()
        XCTAssertTrue(hostSaw("input: key 53 down", after: before), "esc on the bar did not reach the Mac")

        before = hostLog().count
        key("bar-command").tap()
        XCTAssertTrue(hostSaw("input: modifier 55 down", after: before), "Command did not latch on the Mac")
        sleep(1)
        let beforeC = hostLog().count
        app.typeText("c")
        XCTAssertTrue(hostSaw("input: key 8 down flags=cmd", after: beforeC), "Command then c was not sent as Command-C")
        XCTAssertTrue(hostSaw("input: modifier 55 up", after: beforeC), "The latched Command was not let go")
        XCTAssertEqual(typedCount(after: beforeC), 0, "Command then c was typed as text")

        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.lifetime = .keepAlways
        add(shot)

        // The bar's trackpad key: the iOS keyboard goes away and the bottom becomes one big trackpad.
        let gone = NSPredicate(format: "exists == false")
        key("bar-pad").tap()
        expectation(for: gone, evaluatedWith: systemKeyboard)
        waitForExpectations(timeout: 5)
        XCTAssertTrue(key("bar-esc").exists, "The modifier bar went away with the keyboard")
        XCTAssertTrue(trackpad.waitForExistence(timeout: 5), "No trackpad in pad mode")
        XCTAssertGreaterThanOrEqual(trackpad.frame.height, 150, "The pad-mode trackpad is too short")
        sleep(1)
        before = hostLog().count
        trackpad.tap()
        XCTAssertTrue(hostSaw("input: button 0 down x1", after: before), "A tap on the pad-mode trackpad did not click")
        let padShot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        padShot.lifetime = .keepAlways
        add(padShot)
        key("bar-pad").tap()
        XCTAssertTrue(systemKeyboard.waitForExistence(timeout: 5), "The iOS keyboard did not come back after pad mode")

        key("bar-mac-keyboard").tap()
        XCTAssertTrue(key("key-4").waitForExistence(timeout: 5), "The Mac keyboard did not come back")
        XCTAssertTrue(trackpad.exists)
        expectation(for: gone, evaluatedWith: systemKeyboard)
        waitForExpectations(timeout: 5)

        // The keyboard key on the Mac keyboard's top row goes the other way.
        key("fkey-5").tap()
        XCTAssertTrue(key("bar-mac-keyboard").waitForExistence(timeout: 5), "The keyboard key did not bring up the iPhone keyboard")
    }

    /// Half open with the iOS keyboard shorter than the bottom half: the strip between the fold and
    /// the bar is a working trackpad, and the bar's trackpad key gives the whole bottom half.
    func testHalfOpenStrip() {
        // Cover screen forced into the laptop layout: fold at 339, keyboard top faked at 450, bar at 404.
        launch(["-keyboardStyle", "iphone", "-forceHinge", "half", "-fakeKeyboardTop", "450"])
        XCTAssertNotNil(ProcessInfo.processInfo.environment["HOST_LOG"], "Set TEST_RUNNER_HOST_LOG to the host's log file")
        let tip = app.buttons["Continue"]
        if tip.waitForExistence(timeout: 5) { tip.tap() }
        let trackpad = key("trackpad")
        XCTAssertTrue(trackpad.waitForExistence(timeout: 10), "No trackpad strip under the fold")
        XCTAssertTrue(key("bar-esc").exists, "The bar is missing")
        sleep(3) // let the stream come up
        let strip = trackpad.frame
        XCTAssertGreaterThanOrEqual(strip.height, 36, "The strip is too thin to use")
        XCTAssertLessThan(strip.height, 150, "Expected the thin strip, not the full trackpad")
        XCTAssertLessThanOrEqual(strip.maxY, key("bar-esc").frame.minY, "The strip runs under the bar")

        var before = hostLog().count
        trackpad.tap()
        XCTAssertTrue(hostSaw("input: button 0 down x1", after: before), "A tap on the strip did not click")
        before = hostLog().count
        trackpad.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5))
            .press(forDuration: 0.05, thenDragTo: trackpad.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5)))
        XCTAssertTrue(hostSaw("input: move", after: before), "A drag along the strip did not move the pointer")

        key("bar-pad").tap()
        let grown = NSPredicate { _, _ in trackpad.frame.height > 150 }
        expectation(for: grown, evaluatedWith: nil)
        waitForExpectations(timeout: 5)

        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// Landscape: the bar along the bottom with the picture above it; the bar's trackpad key brings up
    /// typing with a trackpad beside the picture, and takes it away again.
    func testLandscapeKeys() {
        // The Duo simulator does not turn for XCUIDevice, so the app asks for landscape itself 2 s after connecting.
        launch(["-fakeKeyboardTop", "300", "-turnTo", "4"])
        XCTAssertNotNil(ProcessInfo.processInfo.environment["HOST_LOG"], "Set TEST_RUNNER_HOST_LOG to the host's log file")
        let trackpad = key("trackpad")
        XCTAssertTrue(key("bar-esc").waitForExistence(timeout: 15), "No bar in landscape")
        sleep(1)
        XCTAssertFalse(key("bar-mac-keyboard").exists, "The Mac keyboard key should be hidden in landscape")
        XCTAssertFalse(trackpad.exists && trackpad.isHittable, "No trackpad in landscape until the trackpad key is on")

        key("bar-pad").tap()
        let shown = NSPredicate { _, _ in trackpad.exists && trackpad.frame.width >= 150 }
        expectation(for: shown, evaluatedWith: nil)
        waitForExpectations(timeout: 5)
        XCTAssertGreaterThanOrEqual(trackpad.frame.width, 150, "The landscape trackpad is too narrow")
        sleep(1)
        let before = hostLog().count
        trackpad.tap()
        XCTAssertTrue(hostSaw("input: button 0 down x1", after: before), "A tap on the landscape trackpad did not click")
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.lifetime = .keepAlways
        add(shot)

        key("bar-pad").tap()
        let gone = NSPredicate { _, _ in !trackpad.exists }
        expectation(for: gone, evaluatedWith: nil)
        waitForExpectations(timeout: 5)
    }

    /// The tall hold iOS will not turn to: our own half turn, with the drawn Mac keyboard. Keys and
    /// the trackpad must still take touches where they are drawn.
    func testFlippedKeys() {
        launch(["-keyboardStyle", "mac", "-flipped", "YES"])
        XCTAssertNotNil(ProcessInfo.processInfo.environment["HOST_LOG"], "Set TEST_RUNNER_HOST_LOG to the host's log file")
        let four = key("key-4")
        XCTAssertTrue(four.waitForExistence(timeout: 10), "Flipped, the drawn Mac keyboard should be up")
        XCTAssertFalse(key("bar-esc").exists, "No iOS keyboard bar while flipped")
        sleep(3)
        var before = hostLog().count
        four.tap()
        XCTAssertTrue(hostSaw("input: key 4 down", after: before), "A key did not register while flipped")
        before = hostLog().count
        key("trackpad").tap()
        XCTAssertTrue(hostSaw("input: button 0 down x1", after: before), "The trackpad did not click while flipped")
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// What the host was sent after `offset`, as tokens: "t<N>" for N characters of text, "b" for a backspace.
    private func typingEvents(after offset: Int) -> [String] {
        let log = hostLog()
        guard log.count > offset else { return [] }
        var tokens: [String] = []
        for line in log.dropFirst(offset).split(separator: "\n") {
            if let range = line.range(of: "input: text ") {
                tokens.append("t" + line[range.upperBound...].prefix { $0.isNumber })
            } else if line.contains("input: key 51 down") {
                tokens.append("b")
            }
        }
        return tokens
    }

    /// Waits until the host has been sent exactly `expected` (text and backspaces) after `offset`.
    private func waitForTyping(_ expected: [String], after offset: Int, timeout: TimeInterval = 5) -> [String] {
        let end = Date().addingTimeInterval(timeout)
        var got = typingEvents(after: offset)
        while got != expected, Date() < end {
            Thread.sleep(forTimeInterval: 0.2)
            got = typingEvents(after: offset)
        }
        return got
    }

    /// Length of the text the Mac ends up with, replaying text and backspaces.
    private func replayedLength(_ tokens: [String]) -> Int {
        tokens.reduce(0) { $1 == "b" ? max($0 - 1, 0) : $0 + (Int($1.dropFirst()) ?? 0) }
    }

    private func tapKeys(_ ids: [String]) {
        for id in ids { key("pk-\(id)").tap() }
    }

    /// The buffer the drawn keys typed into (the hidden proxy's text).
    private func typedBuffer() -> String {
        app.textViews["typing-proxy"].value as? String ?? "<no proxy>"
    }

    /// The flipped hold with iPhone keys: the app's own phone keyboard, with autocorrect and auto-capitals,
    /// typing through the same pipeline as the iOS keyboard.
    func testFlippedIPhoneKeyboard() {
        // Undoing "teh" below teaches the checker the word; each run starts without it.
        launch(["-keyboardStyle", "iphone", "-flipped", "YES", "-unlearnWords", "teh"])
        XCTAssertNotNil(ProcessInfo.processInfo.environment["HOST_LOG"], "Set TEST_RUNNER_HOST_LOG to the host's log file")
        let keys = key("phone-keyboard")
        XCTAssertTrue(keys.waitForExistence(timeout: 10), "Flipped with iPhone keys, the drawn phone keyboard should be up")
        XCTAssertFalse(key("key-4").exists, "The Mac keyboard should be hidden")
        XCTAssertTrue(key("bar-esc").exists, "The modifier bar is missing")
        XCTAssertFalse(app.keyboards.element.exists, "The system keyboard must not come up while flipped")
        sleep(3) // let the stream come up

        // "helo wrold " -> "Hello world ": an auto-capital and two corrections.
        var before = hostLog().count
        tapKeys(["h", "e", "l", "o", "space"])
        // H e l o, then the fix: one backspace and "lo ".
        XCTAssertEqual(waitForTyping(["t1", "t1", "t1", "t1", "b", "t3"], after: before), ["t1", "t1", "t1", "t1", "b", "t3"])
        let middle = hostLog().count
        tapKeys(["w", "r", "o", "l", "d", "space"])
        // w r o l d, then four backspaces and "orld ".
        let second = ["t1", "t1", "t1", "t1", "t1", "b", "b", "b", "b", "t5"]
        XCTAssertEqual(waitForTyping(second, after: middle), second)
        XCTAssertEqual(replayedLength(typingEvents(after: before)), "Hello world ".count)
        XCTAssertEqual(typedBuffer(), "Hello world ")
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.lifetime = .keepAlways
        add(shot)

        // "teh " becomes "the ".
        before = hostLog().count
        tapKeys(["t", "e", "h"])
        XCTAssertEqual(key("pk-suggest-0").label, "\u{201C}teh\u{201D}", "The strip should offer the word as typed")
        XCTAssertEqual(key("pk-suggest-1").label, "the", "The strip should offer the correction")
        let stripShot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        stripShot.name = "half-typed"
        stripShot.lifetime = .keepAlways
        add(stripShot)
        key("pk-space").tap()
        XCTAssertEqual(waitForTyping(["t1", "t1", "t1", "b", "b", "t3"], after: before), ["t1", "t1", "t1", "b", "b", "t3"])
        XCTAssertEqual(typedBuffer(), "Hello world the ")

        // With Option latched, delete straight after the correction is one Option-backspace (a word on the Mac),
        // never the undo; the buffer is unknown after it.
        before = hostLog().count
        key("bar-option").tap()
        key("pk-delete").tap()
        XCTAssertEqual(waitForTyping(["b"], after: before), ["b"])
        XCTAssertTrue(hostSaw("input: key 51 down flags=opt", after: before), "The backspace did not carry Option")
        XCTAssertTrue(hostSaw("input: modifier 58 up", after: before), "Option was not let go after the delete")
        sleep(1)
        XCTAssertEqual(typingEvents(after: before), ["b"], "Option-delete must send exactly one backspace")
        XCTAssertEqual(typedBuffer(), "", "The buffer should be forgotten after Option-delete")

        // A backspace straight after a correction puts back what was typed. Shift off first: the empty
        // buffer starts a sentence.
        key("pk-shift").tap()
        before = hostLog().count
        tapKeys(["t", "e", "h", "space"])
        XCTAssertEqual(waitForTyping(["t1", "t1", "t1", "b", "b", "t3"], after: before), ["t1", "t1", "t1", "b", "b", "t3"])
        XCTAssertEqual(typedBuffer(), "the ")
        before = hostLog().count
        key("pk-delete").tap()
        XCTAssertEqual(waitForTyping(["b", "b", "b", "t2"], after: before), ["b", "b", "b", "t2"])
        XCTAssertEqual(typedBuffer(), "teh", "Backspace after a correction did not restore what was typed")

        // Numbers plane.
        key("pk-plane").tap()
        XCTAssertTrue(key("pk-1").waitForExistence(timeout: 3), "No numbers plane")
        before = hostLog().count
        key("pk-1").tap()
        XCTAssertEqual(waitForTyping(["t1"], after: before), ["t1"], "A digit did not reach the Mac")
        XCTAssertEqual(typedBuffer(), "teh1")
        key("pk-plane").tap()
        XCTAssertTrue(key("pk-h").waitForExistence(timeout: 3), "No way back to letters")

        // The bar's trackpad key: the phone keyboard goes away and the bottom is trackpad; then back.
        let trackpad = key("trackpad")
        let gone = NSPredicate(format: "exists == false")
        key("bar-pad").tap()
        expectation(for: gone, evaluatedWith: keys)
        waitForExpectations(timeout: 5)
        XCTAssertTrue(trackpad.waitForExistence(timeout: 5) && trackpad.isHittable, "No trackpad in pad mode")
        sleep(1)
        before = hostLog().count
        trackpad.tap()
        XCTAssertTrue(hostSaw("input: button 0 down x1", after: before), "The pad-mode trackpad did not click while flipped")
        let padShot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        padShot.lifetime = .keepAlways
        add(padShot)
        key("bar-pad").tap()
        XCTAssertTrue(keys.waitForExistence(timeout: 5), "The phone keyboard did not come back after pad mode")
        sleep(1)

        // Typing mode: the strip between the picture and the bar is trackpad when it is tall enough (70 pt);
        // on the cover screen it is not (as with the iOS keyboard there), and the Mac picture takes the click.
        before = hostLog().count
        if trackpad.exists && trackpad.isHittable {
            trackpad.tap()
        } else {
            // Turned half way round, the picture is on the far side of the bar from the keys.
            let bar = key("bar-esc").frame
            let window = app.windows.firstMatch.frame
            let keysBelow = keys.frame.midY > bar.midY
            let y = keysBelow ? (window.minY + bar.minY) / 2 : (bar.maxY + window.maxY) / 2
            app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: window.midX, dy: y)).tap()
        }
        XCTAssertTrue(hostSaw("input: button 0 down x1", after: before), "Typing mode took no click while flipped")
    }

    /// With Press to click off, holding still then moving drags, as before.
    func testHoldThenDrag() {
        launch(["-pressToClick", "NO"])
        let trackpad = key("trackpad")
        XCTAssertTrue(trackpad.waitForExistence(timeout: 10))
        sleep(3) // let the stream come up

        let start = trackpad.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5))
        let end = trackpad.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.6))
        let before = hostLog().count
        start.press(forDuration: 0.7, thenDragTo: end)
        sleep(1)
        if ProcessInfo.processInfo.environment["HOST_LOG"] != nil {
            XCTAssertTrue(hostSaw("input: button 0 down x1", after: before), "Holding still did not press the button")
            XCTAssertTrue(hostSaw("input: move", after: before), "The drag did not move")
            XCTAssertTrue(hostSaw("input: button 0 up x1", after: before), "The drag did not let go")
        }

        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// The demo: no Mac and no network. The drawn Mac keyboard types on the pretend Mac, the trackpad moves
    /// and clicks, and the menu's first item ends the demo back on the pairing screen.
    func testDemo() {
        launchUnpaired(["-demo", "YES", "-keyboardStyle", "mac"])
        XCTAssertTrue(key("demo-pill").waitForExistence(timeout: 10), "No Demo pill on the pretend Mac")
        let mac = key("demo-mac")
        XCTAssertTrue(mac.exists, "No pretend Mac picture")
        XCTAssertTrue(key("key-4").exists, "No Mac keyboard")
        let trackpad = key("trackpad")
        XCTAssertTrue(trackpad.exists, "No trackpad")
        func typed(_ expected: String) -> Bool {
            let end = Date().addingTimeInterval(3)
            while (mac.value as? String) != expected, Date() < end { Thread.sleep(forTimeInterval: 0.1) }
            return (mac.value as? String) == expected
        }
        XCTAssertEqual(mac.value as? String ?? "", "", "The demo should start with nothing typed")

        // Latched Shift, h, i, space, a, a, backspace: "Hi a".
        key("mod-56").tap()
        for id in ["key-4", "key-34", "key-49", "key-0", "key-0", "key-51"] { key(id).tap() }
        XCTAssertTrue(typed("Hi a"), "Typed text on the pretend Mac is \(mac.value ?? "nil")")
        // Return, a word, then Option-Backspace takes the word and Command-Backspace the line break.
        for id in ["key-36", "key-31", "key-45"] { key(id).tap() } // Return, o, n
        XCTAssertTrue(typed("Hi a\non"), "Typed text on the pretend Mac is \(mac.value ?? "nil")")
        key("mod-58").tap()
        key("key-51").tap()
        XCTAssertTrue(typed("Hi a\n"), "Option-Backspace did not delete the word: \(mac.value ?? "nil")")
        key("mod-55").tap()
        key("key-51").tap()
        XCTAssertTrue(typed("Hi a"), "Command-Backspace did not delete back to the line: \(mac.value ?? "nil")")
        key("mod-55").tap()
        key("key-51").tap()
        XCTAssertTrue(typed(""), "Command-Backspace did not clear the line: \(mac.value ?? "nil")")
        key("key-17").tap() // t
        XCTAssertTrue(typed("t"))

        // Trackpad: move, click, double click, two-finger click; nothing may crash.
        trackpad.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5))
            .press(forDuration: 0.05, thenDragTo: trackpad.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.3)))
        trackpad.tap()
        trackpad.doubleTap()
        trackpad.twoFingerTap()
        mac.tap() // a click straight on the picture
        XCTAssertTrue(mac.exists && key("demo-pill").exists, "The demo went away after using the trackpad")
        XCTAssertEqual(mac.value as? String, "t", "Clicks changed the typed text")
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.lifetime = .keepAlways
        add(shot)

        app.buttons["Menu"].tap()
        let end = app.buttons["End demo"]
        XCTAssertTrue(end.waitForExistence(timeout: 5), "The menu has no End demo")
        end.tap()
        XCTAssertTrue(key("pair-demo").waitForExistence(timeout: 5), "End demo did not return to the pairing screen")
        XCTAssertTrue(key("pair-scan").exists)
        XCTAssertFalse(key("demo-mac").exists, "The pretend Mac is still there")
    }

    /// A fresh install: the pairing screen explains where the Mac side comes from and offers the demo,
    /// all on one screen without scrolling.
    func testPairingScreen() {
        launchUnpaired(["-forgetPairing", "YES"])
        for id in ["pair-scan", "pair-paste", "pair-demo", "pair-host-link", "pair-share", "pair-privacy"] {
            let element = key(id)
            XCTAssertTrue(element.waitForExistence(timeout: 10), "\(id) is missing")
            XCTAssertTrue(element.isHittable, "\(id) is off screen")
        }
        XCTAssertEqual(key("pair-host-link").label, "https://github.com/TheRealJadenKwek/clamshell/releases/latest")
        let window = app.windows.firstMatch.frame
        XCTAssertLessThanOrEqual(key("pair-privacy").frame.maxY, window.maxY, "The privacy link is below the screen")
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// Opens a link through the system, as a tapped link in another app would, so the running app gets it
    /// (`XCUIApplication.open` relaunches the app instead). Accepts the system's "Open in" prompt if it shows.
    private func openFromOutside(_ link: String) {
        XCUIDevice.shared.system.open(URL(string: link)!)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let open = springboard.buttons["Open"]
        if open.waitForExistence(timeout: 2) { open.tap() }
    }

    /// A pairing link from outside the app never pairs silently: unpaired, it asks first (and Cancel keeps the
    /// phone unpaired); a link without a key is ignored; already paired, it is turned away.
    func testPairingLinks() {
        // A made-up Mac on a documentation-only address with a made-up key; nothing is ever dialled.
        let made = "clamshell://pair?name=Test%20Mac&port=47899&key=AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8&h=192.0.2.10"
        launchUnpaired(["-forgetPairing", "YES"])
        XCTAssertTrue(key("pair-scan").waitForExistence(timeout: 10))
        openFromOutside(made)
        let confirm = app.alerts["Pair with this Mac?"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "An outside pairing link did not ask first")
        let message = confirm.staticTexts.allElementsBoundByIndex.map(\.label).joined(separator: " ")
        XCTAssertTrue(message.contains("Test Mac") && message.contains("192.0.2.10") && message.contains("47899"),
                      "The confirm does not show the name, address and port: \(message)")
        XCTAssertTrue(confirm.buttons["Pair"].exists)
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.lifetime = .keepAlways
        add(shot)
        confirm.buttons["Cancel"].tap()
        XCTAssertTrue(key("pair-scan").waitForExistence(timeout: 5), "Cancel left the pairing screen")
        XCTAssertFalse(key("trackpad").exists, "Cancel paired anyway")

        // No key: refused quietly.
        openFromOutside("clamshell://pair?name=Test%20Mac&port=47899&h=192.0.2.10")
        XCTAssertFalse(app.alerts.firstMatch.waitForExistence(timeout: 3), "A link without a key was not ignored")
        XCTAssertTrue(key("pair-scan").exists)

        // In the demo: the confirm shows over it, and Cancel leaves the demo running.
        key("pair-demo").tap()
        XCTAssertTrue(key("demo-mac").waitForExistence(timeout: 5))
        openFromOutside(made)
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "A pairing link in the demo did not ask first")
        confirm.buttons["Cancel"].tap()
        XCTAssertTrue(key("demo-mac").waitForExistence(timeout: 5), "Cancel ended the demo")
        XCTAssertFalse(confirm.exists)

        // A name with line breaks and a fake port line shows as one clean line, and a second link opened while
        // the confirm is up changes nothing: Pair pairs what was shown (ending the demo).
        let dirty = "clamshell://pair?name=Evil%0Aport%2047800%0A%0A%0D%09Mac&port=47899"
            + "&key=AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8&h=192.0.2.10"
        let other = "clamshell://pair?name=Second%20Mac&port=47898&key=HyAhIiMkJSYnKCkqKywtLi8wMTIzNDU2Nzg5Ojs8PT4&h=192.0.2.20"
        openFromOutside(dirty)
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "The link with a dirty name did not ask first")
        func shownLines() -> [String] {
            let text = confirm.staticTexts.allElementsBoundByIndex.map(\.label).first { $0.contains("47899") } ?? ""
            return text.components(separatedBy: "\n")
        }
        XCTAssertEqual(shownLines(), ["Evil port 47800 Mac", "192.0.2.10", "port 47899"], "The confirm is not three clean lines")
        openFromOutside(other)
        sleep(1)
        XCTAssertEqual(shownLines().first, "Evil port 47800 Mac", "A second link changed the confirm")
        let cleanShot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        cleanShot.lifetime = .keepAlways
        add(cleanShot)
        confirm.buttons["Pair"].tap()
        XCTAssertTrue(key("trackpad").waitForExistence(timeout: 10), "Pair did not open the session")
        XCTAssertFalse(key("demo-mac").exists, "Pair did not end the demo")
        XCTAssertFalse(app.alerts["Pair with this Mac?"].waitForExistence(timeout: 2), "The second link was queued behind the first")
        app.buttons["Menu"].tap()
        XCTAssertTrue(app.buttons["Evil port 47800 Mac"].waitForExistence(timeout: 5), "Paired with something other than what was shown")
        XCTAssertFalse(app.buttons["Second Mac"].exists)
        app.buttons["Forget this Mac"].tap()
        let forget = app.alerts["Forget this Mac?"]
        XCTAssertTrue(forget.waitForExistence(timeout: 5))
        forget.buttons["Forget"].tap()
        XCTAssertTrue(key("pair-scan").waitForExistence(timeout: 5), "Forget did not return to the pairing screen")

        // Already paired (with the test host): turned away, and the session stays.
        app.terminate()
        launch()
        XCTAssertTrue(key("trackpad").waitForExistence(timeout: 10))
        openFromOutside(made)
        let refused = app.alerts.matching(NSPredicate(format: "label BEGINSWITH 'Already paired with'")).firstMatch
        XCTAssertTrue(refused.waitForExistence(timeout: 5), "A pairing link re-paired an already paired phone, or said nothing")
        let refusedShot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        refusedShot.lifetime = .keepAlways
        add(refusedShot)
        refused.buttons["OK"].tap()
        XCTAssertTrue(key("trackpad").waitForExistence(timeout: 5), "The session went away")
        XCTAssertFalse(app.alerts["Pair with this Mac?"].exists)
    }
}
