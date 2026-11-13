import Foundation
import CoreGraphics
import AppKit
import ApplicationServices

/// Set from any thread when the host cuts a connection (Disconnect, New key). The injector checks it before
/// every event and every chunk of text, so nothing more is typed even before the server queue gets to the end.
final class StopFlag {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    func set() {
        lock.lock(); defer { lock.unlock() }
        value = true
    }
}

/// Turns the phone's input events into real mouse and keyboard events on this Mac.
/// Needs Accessibility permission. Used from one queue only: the one passed in, which text typing
/// also paces itself on.
final class InputInjector {
    /// When true, nothing is posted; events are only reported through `onEvent`.
    var dryRun = false
    var onEvent: ((String) -> Void)?
    var display: DisplayInfo

    /// Largest pointer move and scroll one event can ask for, in points and pixels. A phone never comes close.
    static let maxMove: Float = 10_000
    static let maxScroll: Float = 10_000
    /// Events waiting behind text that is still being typed, and the text among them, at most. A megabyte
    /// of text takes a few minutes to type; a paste longer than that is typed up to here and stopped.
    static let maxWaitingEvents = 100_000
    static let maxWaitingTextBytes = 1024 * 1024
    /// Text goes out this many UTF-16 units per key event, with this pause between events.
    private static let chunkUnits = 16
    private static let chunkPause = 0.002

    private let queue: DispatchQueue
    private let stop: StopFlag
    private var stopLogged = false
    private let source: CGEventSource?
    private var flags: CGEventFlags = []
    private var keysDown = Set<UInt16>()
    private var buttonsDown = Set<UInt8>()
    private var capsLock = false
    private var lastClickTime: [UInt8: TimeInterval] = [:]
    private var lastClickPoint: [UInt8: CGPoint] = [:]
    private var clickCount: [UInt8: Int64] = [:]
    private var dryRunCursor = CGPoint(x: 0.5, y: 0.5)
    private var scrollRemainder = CGPoint.zero

    /// Text being typed a chunk at a time, so the queue stays free between chunks for Disconnect,
    /// New key and the next message. Events that arrive meanwhile wait their turn in `waiting`.
    private struct Typing {
        var units: [UInt16]
        var index: Int
        var characters: Int
    }
    private var typing: Typing?
    private var typingTicket = 0
    private var waiting: [InputEvent] = []
    private var waitingHead = 0
    private var waitingTextBytes = 0
    private var droppingWaiting = false
    /// Set once the text cap cut a paste short: the rest of it is dropped until the Mac has caught up.
    private var droppingText = false

    private static let modifierFlags: [UInt16: CGEventFlags] = [
        55: .maskCommand, 54: .maskCommand,
        56: .maskShift, 60: .maskShift,
        58: .maskAlternate, 61: .maskAlternate,
        59: .maskControl, 62: .maskControl,
    ]
    private static let capsLockKey: UInt16 = 57

    init(display: DisplayInfo, queue: DispatchQueue, stop: StopFlag = StopFlag()) {
        self.display = display
        self.queue = queue
        self.stop = stop
        source = CGEventSource(stateID: .hidSystemState)
        source?.localEventsSuppressionInterval = 0
    }

    static var hasPermission: Bool { AXIsProcessTrusted() }

    /// Normalized cursor position on the shared display, for the phone's zoom-follow.
    func cursorPosition() -> CGPoint {
        if dryRun { return dryRunCursor }
        guard let p = CGEvent(source: nil)?.location else { return CGPoint(x: 0.5, y: 0.5) }
        let b = display.bounds
        return CGPoint(x: (p.x - b.minX) / max(b.width, 1), y: (p.y - b.minY) / max(b.height, 1))
    }

    func handle(_ event: InputEvent) {
        guard let event = Self.sanitized(event) else { return }
        if typing != nil || waitingHead < waiting.count {
            wait(event)
        } else {
            perform(event)
        }
    }

    /// Drops events carrying numbers that are not finite and clamps the rest to what a phone can mean,
    /// so nothing a phone sends can overflow a conversion to an integer or flood the held-key set.
    static func sanitized(_ event: InputEvent) -> InputEvent? {
        func clamp(_ v: Float, _ limit: Float) -> Float { min(max(v, -limit), limit) }
        switch event {
        case .moveRel(let dx, let dy):
            guard dx.isFinite, dy.isFinite else { return nil }
            return .moveRel(dx: clamp(dx, maxMove), dy: clamp(dy, maxMove))
        case .moveAbs(let x, let y):
            guard x.isFinite, y.isFinite else { return nil }
            return .moveAbs(x: min(max(x, 0), 1), y: min(max(y, 0), 1))
        case .scroll(let dx, let dy):
            guard dx.isFinite, dy.isFinite else { return nil }
            return .scroll(dx: clamp(dx, maxScroll), dy: clamp(dy, maxScroll))
        case .button(let index, let down, let clicks):
            return .button(index: min(index, 2), down: down, clicks: min(clicks, 3))
        case .key(let code, _, _):
            return code <= 255 ? event : nil
        case .text(let text):
            return text.isEmpty ? nil : event
        case .media, .action, .releaseAll:
            return event
        }
    }

    /// True once the connection was cut: says so once, and nothing more is posted.
    private var stopped: Bool {
        guard stop.isSet else { return false }
        if !stopLogged {
            stopLogged = true
            log("input: stopped, the connection was cut")
        }
        return true
    }

    private func perform(_ event: InputEvent) {
        if stopped { return }
        switch event {
        case .moveRel(let dx, let dy):
            moveBy(CGFloat(dx), CGFloat(dy))
        case .moveAbs(let x, let y):
            let b = display.bounds
            moveTo(CGPoint(x: b.minX + CGFloat(x) * b.width, y: b.minY + CGFloat(y) * b.height), delta: .zero)
        case .button(let index, let down, let clicks):
            button(index, down: down, clicks: clicks)
        case .scroll(let dx, let dy):
            scroll(CGFloat(dx), CGFloat(dy))
        case .key(let code, let down, let isRepeat):
            key(code, down: down, isRepeat: isRepeat)
        case .media(let key, let down):
            media(key, down: down)
        case .text(let text):
            type(text)
        case .action(let raw):
            action(raw)
        case .releaseAll:
            releaseHeld()
        }
    }

    private func wait(_ event: InputEvent) {
        guard waiting.count - waitingHead < Self.maxWaitingEvents else {
            if !droppingWaiting {
                droppingWaiting = true
                log("input: the phone is sending faster than the Mac can keep up with; dropping input until it catches up")
            }
            return
        }
        guard case .text(let text) = event else {
            waiting.append(event)
            return
        }
        if droppingText { return }
        let room = Self.maxWaitingTextBytes - waitingTextBytes
        var kept = text
        if text.utf8.count > room {
            // Keep what fits, ending on a whole character, and stop the paste there.
            kept = ""
            var bytes = 0
            for character in text {
                let size = character.utf8.count
                if bytes + size > room { break }
                kept.append(character)
                bytes += size
            }
            droppingText = true
            log("input: more than \(Self.maxWaitingTextBytes / 1024) KB of text waiting to be typed; this paste stops after \(waitingTextBytes + kept.utf8.count) bytes")
            if kept.isEmpty { return }
        }
        waiting.append(.text(kept))
        waitingTextBytes += kept.utf8.count
    }

    private func performWaiting() {
        while typing == nil, waitingHead < waiting.count {
            let event = waiting[waitingHead]
            waitingHead += 1
            if case .text(let text) = event { waitingTextBytes -= text.utf8.count }
            perform(event)
        }
        if waitingHead >= waiting.count {
            waiting.removeAll(keepingCapacity: true)
            waitingHead = 0
            waitingTextBytes = 0
            droppingWaiting = false
            droppingText = false
        }
    }

    /// Lets go of everything the phone was holding and drops text not typed yet, so a dropped
    /// connection never leaves Command or a mouse button stuck down or keeps typing.
    func releaseAll() {
        cancelWaiting()
        releaseHeld()
    }

    private func cancelWaiting() {
        typingTicket += 1
        var units = 0
        if let typing { units += typing.units.count - typing.index }
        let events = waiting.count - waitingHead
        for event in waiting[waitingHead...] {
            if case .text(let text) = event { units += text.utf16.count }
        }
        typing = nil
        waiting.removeAll()
        waitingHead = 0
        waitingTextBytes = 0
        droppingWaiting = false
        droppingText = false
        if units > 0 || events > 0 {
            log("input: dropped \(events) waiting events and \(units) text units not typed yet")
        }
    }

    private func releaseHeld() {
        for index in buttonsDown { button(index, down: false, clicks: 1) }
        for code in keysDown { key(code, down: false, isRepeat: false) }
        flags = capsLock ? [.maskAlphaShift] : []
        buttonsDown.removeAll()
        keysDown.removeAll()
    }

    // MARK: Mouse

    private func currentLocation() -> CGPoint {
        if dryRun {
            let b = display.bounds
            return CGPoint(x: b.minX + dryRunCursor.x * b.width, y: b.minY + dryRunCursor.y * b.height)
        }
        return CGEvent(source: nil)?.location ?? CGPoint(x: display.bounds.midX, y: display.bounds.midY)
    }

    private func moveBy(_ dx: CGFloat, _ dy: CGFloat) {
        let p = currentLocation()
        moveTo(CGPoint(x: p.x + dx, y: p.y + dy), delta: CGPoint(x: dx, y: dy))
    }

    private func moveTo(_ target: CGPoint, delta: CGPoint) {
        let b = display.bounds
        let p = CGPoint(x: min(max(target.x, b.minX), b.maxX - 1), y: min(max(target.y, b.minY), b.maxY - 1))
        if dryRun {
            dryRunCursor = CGPoint(x: (p.x - b.minX) / b.width, y: (p.y - b.minY) / b.height)
            onEvent?(String(format: "move %.0f,%.0f", p.x, p.y))
            return
        }
        let type: CGEventType
        let mouseButton: CGMouseButton
        if buttonsDown.contains(0) { type = .leftMouseDragged; mouseButton = .left }
        else if buttonsDown.contains(1) { type = .rightMouseDragged; mouseButton = .right }
        else if buttonsDown.contains(2) { type = .otherMouseDragged; mouseButton = .center }
        else { type = .mouseMoved; mouseButton = .left }
        guard let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: p, mouseButton: mouseButton) else { return }
        e.setIntegerValueField(.mouseEventDeltaX, value: Int64(delta.x.rounded()))
        e.setIntegerValueField(.mouseEventDeltaY, value: Int64(delta.y.rounded()))
        e.flags = flags
        e.post(tap: .cghidEventTap)
    }

    private func button(_ index: UInt8, down: Bool, clicks: UInt8) {
        let p = currentLocation()
        if down {
            let now = ProcessInfo.processInfo.systemUptime
            var count: Int64 = 1
            if clicks > 0 {
                count = Int64(clicks)
            } else if let t = lastClickTime[index], let lp = lastClickPoint[index],
                      now - t < NSEvent.doubleClickInterval, abs(lp.x - p.x) < 6, abs(lp.y - p.y) < 6 {
                count = min((clickCount[index] ?? 1) + 1, 3)
            }
            clickCount[index] = count
            lastClickTime[index] = now
            lastClickPoint[index] = p
            buttonsDown.insert(index)
        } else {
            guard buttonsDown.contains(index) else { return }
            buttonsDown.remove(index)
        }
        if dryRun {
            onEvent?("button \(index) \(down ? "down" : "up") x\(clickCount[index] ?? 1)")
            return
        }
        let type: CGEventType
        let mouseButton: CGMouseButton
        switch index {
        case 0: type = down ? .leftMouseDown : .leftMouseUp; mouseButton = .left
        case 1: type = down ? .rightMouseDown : .rightMouseUp; mouseButton = .right
        default: type = down ? .otherMouseDown : .otherMouseUp; mouseButton = .center
        }
        guard let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: p, mouseButton: mouseButton) else { return }
        e.setIntegerValueField(.mouseEventClickState, value: clickCount[index] ?? 1)
        e.flags = flags
        e.post(tap: .cghidEventTap)
    }

    private func scroll(_ dx: CGFloat, _ dy: CGFloat) {
        // Whole pixels only; carry the fraction so slow scrolling still moves.
        scrollRemainder.x += dx
        scrollRemainder.y += dy
        let ix = Int32(scrollRemainder.x.rounded(.towardZero))
        let iy = Int32(scrollRemainder.y.rounded(.towardZero))
        scrollRemainder.x -= CGFloat(ix)
        scrollRemainder.y -= CGFloat(iy)
        guard ix != 0 || iy != 0 else { return }
        if dryRun {
            onEvent?("scroll \(ix),\(iy)")
            return
        }
        guard let e = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2, wheel1: iy, wheel2: ix, wheel3: 0) else { return }
        e.flags = flags
        e.post(tap: .cghidEventTap)
    }

    // MARK: Keyboard

    private func key(_ code: UInt16, down: Bool, isRepeat: Bool) {
        if code == Self.capsLockKey {
            guard down else { return }
            capsLock.toggle()
            if capsLock { flags.insert(.maskAlphaShift) } else { flags.remove(.maskAlphaShift) }
            if dryRun { onEvent?("caps \(capsLock ? "on" : "off")"); return }
            postFlagsChanged(code)
            return
        }
        if let flag = Self.modifierFlags[code] {
            if down { keysDown.insert(code) } else { keysDown.remove(code) }
            // A flag stays set while either the left or the right key is held.
            let stillHeld = keysDown.contains { Self.modifierFlags[$0] == flag }
            if stillHeld { flags.insert(flag) } else { flags.remove(flag) }
            if dryRun { onEvent?("modifier \(code) \(down ? "down" : "up")"); return }
            postFlagsChanged(code)
            return
        }
        if down { keysDown.insert(code) } else {
            guard keysDown.contains(code) else { return }
            keysDown.remove(code)
        }
        if dryRun {
            onEvent?("key \(code) \(down ? (isRepeat ? "repeat" : "down") : "up") flags=\(describe(flags))")
            return
        }
        guard let e = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else { return }
        e.flags = flags.union(Self.extraFlags(for: code))
        if isRepeat { e.setIntegerValueField(.keyboardEventAutorepeat, value: 1) }
        e.post(tap: .cghidEventTap)
    }

    /// Arrow, navigation and function keys carry these flags when a real keyboard sends them.
    private static func extraFlags(for code: UInt16) -> CGEventFlags {
        switch code {
        case 123, 124, 125, 126: return [.maskNumericPad, .maskSecondaryFn]
        case 115, 116, 117, 119, 121: return [.maskSecondaryFn]
        case 122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111: return [.maskSecondaryFn]
        default: return []
        }
    }

    private func postFlagsChanged(_ code: UInt16) {
        guard let e = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true) else { return }
        e.type = .flagsChanged
        e.flags = flags
        e.post(tap: .cghidEventTap)
    }

    private func media(_ key: UInt8, down: Bool) {
        if dryRun { onEvent?("media \(key) \(down ? "down" : "up")"); return }
        let state = down ? 0xa : 0xb
        let data1 = (Int(key) << 16) | (state << 8)
        let e = NSEvent.otherEvent(with: .systemDefined, location: .zero,
                                   modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(state << 8)),
                                   timestamp: 0, windowNumber: 0, context: nil, subtype: 8, data1: data1, data2: -1)
        e?.cgEvent?.post(tap: .cghidEventTap)
    }

    /// One chunk now, the next after a short pause on the queue, never blocking it.
    private func type(_ text: String) {
        typing = Typing(units: Array(text.utf16), index: 0, characters: text.count)
        typeNextChunk()
    }

    private func typeNextChunk() {
        guard var t = typing else { return }
        if stopped { return }
        if t.index >= t.units.count {
            typing = nil
            if dryRun { onEvent?("text \(t.characters) chars") }
            performWaiting()
            return
        }
        // In chunks, because one event carries only a short string.
        var end = min(t.index + Self.chunkUnits, t.units.count)
        // Never end a chunk between the two halves of a surrogate pair (emoji).
        if end < t.units.count, end - t.index > 1, UTF16.isLeadSurrogate(t.units[end - 1]) { end -= 1 }
        if !dryRun {
            let chunk = Array(t.units[t.index..<end])
            for down in [true, false] {
                guard let e = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down) else { continue }
                e.flags = []
                chunk.withUnsafeBufferPointer { e.keyboardSetUnicodeString(stringLength: $0.count, unicodeString: $0.baseAddress) }
                e.post(tap: .cghidEventTap)
            }
        }
        t.index = end
        typing = t
        let ticket = typingTicket
        queue.asyncAfter(deadline: .now() + Self.chunkPause) { [weak self] in
            guard let self, ticket == self.typingTicket else { return }
            self.typeNextChunk()
        }
    }

    private func action(_ raw: UInt8) {
        guard let action = HostAction(rawValue: raw) else { return }
        if dryRun { onEvent?("action \(action)"); return }
        switch action {
        case .missionControl:
            DispatchQueue.main.async {
                NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Mission Control.app"))
            }
        case .wakeDisplay:
            Power.wakeDisplay()
        case .forceClick:
            lookUp()
        }
    }

    /// Force Click: Control-Command-D looks up the word under the pointer, which is
    /// what a Mac trackpad's Force Click does by default. The modifiers are added for
    /// this one key only and put back afterwards; what the phone holds is not changed.
    private func lookUp() {
        let held = flags
        var f = held
        let added = [(UInt16(55), CGEventFlags.maskCommand), (UInt16(59), CGEventFlags.maskControl)].filter { !held.contains($0.1) }
        for (code, flag) in added {
            f.insert(flag)
            postFlags(f, code: code)
        }
        for down in [true, false] {
            guard let e = CGEvent(keyboardEventSource: source, virtualKey: 2, keyDown: down) else { continue }
            e.flags = f
            e.post(tap: .cghidEventTap)
        }
        for (code, flag) in added.reversed() {
            f.remove(flag)
            postFlags(f, code: code)
        }
    }

    private func postFlags(_ f: CGEventFlags, code: UInt16) {
        guard let e = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true) else { return }
        e.type = .flagsChanged
        e.flags = f
        e.post(tap: .cghidEventTap)
    }

    private func describe(_ f: CGEventFlags) -> String {
        var parts: [String] = []
        if f.contains(.maskCommand) { parts.append("cmd") }
        if f.contains(.maskShift) { parts.append("shift") }
        if f.contains(.maskAlternate) { parts.append("opt") }
        if f.contains(.maskControl) { parts.append("ctrl") }
        if f.contains(.maskAlphaShift) { parts.append("caps") }
        return parts.isEmpty ? "-" : parts.joined(separator: "+")
    }
}
