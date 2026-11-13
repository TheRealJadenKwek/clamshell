import UIKit

enum KeyKind: Equatable {
    case key(UInt16)        // macOS virtual key code
    case modifier(UInt16)
    case fn
    case caps
    case function(Int)      // 1...12, media by default, F-keys with fn
    case menu
}

struct KeySpec {
    enum Slot { case full, upper, lower, bottomHalf }
    enum Align { case center, left, right }
    var kind: KeyKind
    var label: String = ""
    var top: String?
    var width: CGFloat = 1
    var slot: Slot = .full
    var word: String? = nil   // the name printed on the key
    var align: Align = .center
}

enum MediaAction {
    case media(MediaKey)
    case host(HostAction)
    case combo(modifiers: [UInt16], key: UInt16)
    case display
    case iPhoneKeyboard
}

struct FunctionKey {
    let code: UInt16
    let symbol: String
    let action: MediaAction
    let repeats: Bool

    static let all: [FunctionKey] = [
        FunctionKey(code: 122, symbol: "sun.min", action: .media(.brightnessDown), repeats: true),
        FunctionKey(code: 120, symbol: "sun.max", action: .media(.brightnessUp), repeats: true),
        FunctionKey(code: 99, symbol: "rectangle.3.group", action: .host(.missionControl), repeats: false),
        FunctionKey(code: 118, symbol: "magnifyingglass", action: .combo(modifiers: [55], key: 49), repeats: false),
        // Where a MacBook has dictation: swaps to the iPhone keyboard (autocorrect, swipe, dictation).
        FunctionKey(code: 96, symbol: "keyboard", action: .iPhoneKeyboard, repeats: false),
        FunctionKey(code: 97, symbol: "display", action: .display, repeats: false),
        FunctionKey(code: 98, symbol: "backward.fill", action: .media(.previous), repeats: false),
        FunctionKey(code: 100, symbol: "playpause.fill", action: .media(.play), repeats: false),
        FunctionKey(code: 101, symbol: "forward.fill", action: .media(.next), repeats: false),
        FunctionKey(code: 109, symbol: "speaker.slash.fill", action: .media(.mute), repeats: false),
        FunctionKey(code: 103, symbol: "speaker.wave.1.fill", action: .media(.soundDown), repeats: true),
        FunctionKey(code: 111, symbol: "speaker.wave.3.fill", action: .media(.soundUp), repeats: true),
    ]
}

/// Repeats a held key the way a real keyboard does.
final class KeyRepeater {
    private var timers: [Int: Timer] = [:]

    func start(_ id: Int, action: @escaping () -> Void) {
        stop(id)
        let timer = Timer(timeInterval: 0.38, repeats: false) { [weak self] _ in
            guard let self else { return }
            let fast = Timer(timeInterval: 0.045, repeats: true) { _ in action() }
            RunLoop.main.add(fast, forMode: .common)
            self.timers[id]?.invalidate()
            self.timers[id] = fast
        }
        RunLoop.main.add(timer, forMode: .common)
        timers[id] = timer
    }

    func stop(_ id: Int) {
        timers[id]?.invalidate()
        timers[id] = nil
    }

    func stopAll() {
        timers.values.forEach { $0.invalidate() }
        timers.removeAll()
    }
}

/// A full Mac keyboard drawn on glass. Every key goes down when the finger lands
/// and up when it lifts, so chords and held keys behave like the real thing.
/// Tapping a modifier on its own latches it for the next key.
final class KeyboardView: UIView {
    var send: (([InputEvent]) -> Void)?
    var onDisplay: (() -> Void)?
    var onIPhoneKeyboard: (() -> Void)?
    let menuButton = UIButton(type: .system)

    private let specs: [KeySpec]
    private let rows: [[Int]]
    private var caps: [KeyCapView] = []
    private var slots: [CGRect] = []
    private var touchKeys: [UITouch: Int] = [:]

    private var heldModifiers = Set<UInt16>()
    private var latchedModifiers = Set<UInt16>()
    private var usedModifiers = Set<UInt16>()
    private var unlatchOnRelease = Set<UInt16>()
    private var modifierDownTime: [UInt16: TimeInterval] = [:]
    private var fnHeld = false
    private var fnLatched = false
    private var fnUsed = false
    private var fnUnlatchOnRelease = false
    private var fnDownTime: TimeInterval = 0
    private var capsOn = false
    private var sentCodes: [Int: UInt16] = [:]
    private let repeater = KeyRepeater()

    private var fnActive: Bool { fnHeld || fnLatched }

    private static let spokenNames: [UInt16: String] = [
        53: "Escape", 51: "Delete", 48: "Tab", 36: "Return", 49: "Space", 123: "Left arrow", 124: "Right arrow",
        125: "Down arrow", 126: "Up arrow", 56: "Shift", 60: "Right Shift", 59: "Control", 58: "Option",
        61: "Right Option", 55: "Command", 54: "Right Command",
    ]
    private static let functionNames = ["Brightness down", "Brightness up", "Mission Control", "Spotlight", "iPhone keyboard",
                                        "Display", "Previous track", "Play or pause", "Next track", "Mute", "Volume down", "Volume up"]

    static func height(forWidth width: CGFloat, limit: CGFloat) -> CGFloat {
        let unit = width / 14.5
        let rowHeight = min(max(unit * 0.96, 36), 54)
        return min(rowHeight * 5.62 + 6, limit)
    }

    override init(frame: CGRect) {
        let layout = KeyboardView.makeLayout()
        specs = layout.flatMap { $0 }
        var index = 0
        rows = layout.map { row in row.map { _ in defer { index += 1 }; return index } }
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        backgroundColor = UIColor(red: 0.075, green: 0.075, blue: 0.082, alpha: 1) // the keyboard well
        layer.cornerRadius = 9
        layer.cornerCurve = .continuous
        for spec in specs {
            let cap = KeyCapView(spec: spec)
            cap.isAccessibilityElement = true
            cap.accessibilityTraits = .keyboardKey
            switch spec.kind {
            case .key(let code):
                cap.accessibilityIdentifier = "key-\(code)"
                cap.accessibilityLabel = KeyboardView.spokenNames[code] ?? spec.label
            case .modifier(let code):
                cap.accessibilityIdentifier = "mod-\(code)"
                cap.accessibilityLabel = KeyboardView.spokenNames[code] ?? spec.label
            case .fn:
                cap.accessibilityIdentifier = "key-fn"
                cap.accessibilityLabel = "Function"
            case .caps:
                cap.accessibilityIdentifier = "key-caps"
                cap.accessibilityLabel = "Caps Lock"
            case .function(let n):
                cap.accessibilityIdentifier = "fkey-\(n)"
                cap.accessibilityLabel = KeyboardView.functionNames[n - 1]
            case .menu:
                cap.isAccessibilityElement = false
            }
            caps.append(cap)
            addSubview(cap)
        }
        // Where the Touch ID key sits on the real thing.
        menuButton.setImage(UIImage(systemName: "touchid"), for: .normal)
        menuButton.tintColor = UIColor(white: 1, alpha: 0.32)
        menuButton.backgroundColor = UIColor(white: 0.1, alpha: 1)
        menuButton.showsMenuAsPrimaryAction = true
        menuButton.accessibilityLabel = "Menu"
        addSubview(menuButton)
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: Layout

    private static func makeLayout() -> [[KeySpec]] {
        func k(_ label: String, _ code: UInt16, top: String? = nil, width: CGFloat = 1) -> KeySpec {
            KeySpec(kind: .key(code), label: label, top: top, width: width)
        }
        let functionWidth: CGFloat = 14.5 / 14
        var row0 = [KeySpec(kind: .key(53), label: "esc", width: functionWidth)]
        for i in 1...12 { row0.append(KeySpec(kind: .function(i), width: functionWidth)) }
        row0.append(KeySpec(kind: .menu, width: functionWidth))

        let row1 = [k("`", 50, top: "~"), k("1", 18, top: "!"), k("2", 19, top: "@"), k("3", 20, top: "#"), k("4", 21, top: "$"),
                    k("5", 23, top: "%"), k("6", 22, top: "^"), k("7", 26, top: "&"), k("8", 28, top: "*"), k("9", 25, top: "("),
                    k("0", 29, top: ")"), k("-", 27, top: "_"), k("=", 24, top: "+"), KeySpec(kind: .key(51), label: "⌫", width: 1.5, word: "delete", align: .right)]
        let row2 = [KeySpec(kind: .key(48), label: "⇥", width: 1.5, word: "tab", align: .left), k("Q", 12), k("W", 13), k("E", 14), k("R", 15), k("T", 17), k("Y", 16), k("U", 32),
                    k("I", 34), k("O", 31), k("P", 35), k("[", 33, top: "{"), k("]", 30, top: "}"), k("\\", 42, top: "|")]
        let row3 = [KeySpec(kind: .caps, label: "⇪", width: 1.75, word: "caps lock", align: .left), k("A", 0), k("S", 1), k("D", 2), k("F", 3), k("G", 5), k("H", 4),
                    k("J", 38), k("K", 40), k("L", 37), k(";", 41, top: ":"), k("'", 39, top: "\""), KeySpec(kind: .key(36), label: "\u{21A9}\u{FE0E}", width: 1.75, word: "return", align: .right)]
        let row4 = [KeySpec(kind: .modifier(56), label: "⇧", width: 2.25, word: "shift", align: .left), k("Z", 6), k("X", 7), k("C", 8), k("V", 9), k("B", 11),
                    k("N", 45), k("M", 46), k(",", 43, top: "<"), k(".", 47, top: ">"), k("/", 44, top: "?"),
                    KeySpec(kind: .modifier(60), label: "⇧", width: 2.25, word: "shift", align: .right)]
        let row5 = [KeySpec(kind: .fn, label: "fn"), KeySpec(kind: .modifier(59), label: "⌃", word: "control"), KeySpec(kind: .modifier(58), label: "⌥", word: "option"),
                    KeySpec(kind: .modifier(55), label: "⌘", width: 1.25, word: "command"), k("", 49, width: 5),
                    KeySpec(kind: .modifier(54), label: "⌘", width: 1.25, word: "command"), KeySpec(kind: .modifier(61), label: "⌥", word: "option"),
                    KeySpec(kind: .key(123), label: "◀", slot: .bottomHalf),
                    KeySpec(kind: .key(126), label: "▲", width: 1, slot: .upper),
                    KeySpec(kind: .key(125), label: "▼", width: 0, slot: .lower),
                    KeySpec(kind: .key(124), label: "▶", slot: .bottomHalf)]
        return [row0, row1, row2, row3, row4, row5]
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let pad: CGFloat = 4
        let unit = (bounds.width - pad * 2) / 14.5
        let rowHeight = (bounds.height - pad * 2) / 5.62
        let gap = max(3, min(unit * 0.1, 6))
        slots = Array(repeating: .zero, count: specs.count)
        var y = pad
        for (rowIndex, row) in rows.enumerated() {
            let height = rowIndex == 0 ? rowHeight * 0.62 : rowHeight
            var x = pad
            var previousSlot = CGRect.zero
            for index in row {
                let spec = specs[index]
                var slot: CGRect
                switch spec.slot {
                case .full, .bottomHalf: // a half-height arrow still takes touches across the whole cell
                    slot = CGRect(x: x, y: y, width: spec.width * unit, height: height)
                    x += spec.width * unit
                case .upper:
                    slot = CGRect(x: x, y: y, width: spec.width * unit, height: height / 2)
                    previousSlot = slot
                    x += spec.width * unit
                case .lower:
                    slot = CGRect(x: previousSlot.minX, y: previousSlot.maxY, width: previousSlot.width, height: height / 2)
                }
                slots[index] = slot
                let halfGap = gap / 2
                var frame = slot.insetBy(dx: halfGap, dy: halfGap)
                if spec.slot == .upper { frame = CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: slot.height - halfGap * 1.5) }
                if spec.slot == .lower { frame = CGRect(x: frame.minX, y: slot.minY + halfGap * 0.5, width: frame.width, height: slot.height - halfGap * 1.5) }
                if spec.slot == .bottomHalf { frame = CGRect(x: frame.minX, y: slot.midY + halfGap * 0.5, width: frame.width, height: slot.height / 2 - halfGap * 1.5) }
                caps[index].frame = frame
                if spec.kind == .menu {
                    menuButton.frame = frame
                    menuButton.layer.cornerRadius = min(6, frame.height * 0.2)
                    caps[index].isHidden = true
                }
            }
            y += height
        }
    }

    // MARK: Touches

    private func keyIndex(at point: CGPoint) -> Int? {
        if let hit = slots.firstIndex(where: { $0.contains(point) }) { return specs[hit].kind == .menu ? nil : hit }
        // In the outer padding: take the nearest key.
        var best: (Int, CGFloat)?
        for (i, slot) in slots.enumerated() where specs[i].kind != .menu {
            let dx = max(slot.minX - point.x, 0, point.x - slot.maxX)
            let dy = max(slot.minY - point.y, 0, point.y - slot.maxY)
            let d = dx * dx + dy * dy
            if d < 100, d < (best?.1 ?? .greatestFiniteMagnitude) { best = (i, d) }
        }
        return best?.0
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            guard let index = keyIndex(at: touch.location(in: self)) else { continue }
            // Two fingers on one key count once.
            guard !touchKeys.values.contains(index) else { continue }
            touchKeys[touch] = index
            press(index)
        }
        refresh()
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            guard let index = touchKeys.removeValue(forKey: touch) else { continue }
            release(index)
        }
        refresh()
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        touchesEnded(touches, with: event)
    }

    // MARK: Key logic

    private func press(_ index: Int) {
        Haptics.shared.play(.key)
        let now = ProcessInfo.processInfo.systemUptime
        switch specs[index].kind {
        case .modifier(let code):
            if latchedModifiers.contains(code) {
                unlatchOnRelease.insert(code)
            } else {
                send?([.key(code: code, down: true, isRepeat: false)])
            }
            heldModifiers.insert(code)
            usedModifiers.remove(code)
            modifierDownTime[code] = now
        case .fn:
            if fnLatched { fnUnlatchOnRelease = true }
            fnHeld = true
            fnUsed = false
            fnDownTime = now
        case .caps:
            capsOn.toggle()
            send?([.key(code: 57, down: true, isRepeat: false), .key(code: 57, down: false, isRepeat: false)])
        case .key(let code):
            markModifiersUsed()
            pressCode(translated(code), for: index)
        case .function(let n):
            markModifiersUsed()
            let function = FunctionKey.all[n - 1]
            if fnActive {
                pressCode(function.code, for: index)
            } else {
                perform(function.action)
                if function.repeats {
                    repeater.start(index) { [weak self] in self?.perform(function.action) }
                }
            }
        case .menu:
            break
        }
    }

    private func release(_ index: Int) {
        let now = ProcessInfo.processInfo.systemUptime
        switch specs[index].kind {
        case .modifier(let code):
            heldModifiers.remove(code)
            if unlatchOnRelease.remove(code) != nil {
                latchedModifiers.remove(code)
                send?([.key(code: code, down: false, isRepeat: false)])
            } else if !usedModifiers.contains(code), now - (modifierDownTime[code] ?? 0) < 0.4 {
                latchedModifiers.insert(code) // stays down on the Mac until the next key
            } else {
                send?([.key(code: code, down: false, isRepeat: false)])
            }
        case .fn:
            fnHeld = false
            if fnUnlatchOnRelease {
                fnUnlatchOnRelease = false
                fnLatched = false
            } else if !fnUsed, now - fnDownTime < 0.4 {
                fnLatched = true
            }
        case .caps, .menu:
            break
        case .key, .function:
            repeater.stop(index)
            if let code = sentCodes.removeValue(forKey: index) {
                send?([.key(code: code, down: false, isRepeat: false)])
            }
            consumeLatches()
        }
    }

    private func pressCode(_ code: UInt16, for index: Int) {
        sentCodes[index] = code
        send?([.key(code: code, down: true, isRepeat: false)])
        repeater.start(index) { [weak self] in
            self?.send?([.key(code: code, down: true, isRepeat: true)])
        }
    }

    private func markModifiersUsed() {
        usedModifiers.formUnion(heldModifiers)
        if fnHeld { fnUsed = true }
    }

    /// With fn: arrows become Home, End, Page Up and Page Down, and delete deletes forward.
    private func translated(_ code: UInt16) -> UInt16 {
        guard fnActive else { return code }
        switch code {
        case 123: return 115
        case 124: return 119
        case 126: return 116
        case 125: return 121
        case 51: return 117
        case 36: return 76
        default: return code
        }
    }

    private func perform(_ action: MediaAction) {
        switch action {
        case .media(let key):
            send?([.media(key: key.rawValue, down: true), .media(key: key.rawValue, down: false)])
        case .host(let action):
            send?([.action(action.rawValue)])
        case .combo(let modifiers, let key):
            var events: [InputEvent] = modifiers.map { .key(code: $0, down: true, isRepeat: false) }
            events.append(.key(code: key, down: true, isRepeat: false))
            events.append(.key(code: key, down: false, isRepeat: false))
            events.append(contentsOf: modifiers.reversed().map { .key(code: $0, down: false, isRepeat: false) })
            send?(events)
        case .display:
            onDisplay?()
        case .iPhoneKeyboard:
            onIPhoneKeyboard?()
        }
    }

    /// Latched modifiers apply to one key or one click, then let go.
    func consumeLatches() {
        let release = latchedModifiers.subtracting(heldModifiers)
        if !release.isEmpty {
            send?(release.map { .key(code: $0, down: false, isRepeat: false) })
            latchedModifiers.subtract(release)
        }
        if !fnHeld { fnLatched = false }
        refresh()
    }

    /// Forget every held key, for when the app leaves the screen or the link drops.
    func releaseEverything() {
        repeater.stopAll()
        touchKeys.removeAll()
        sentCodes.removeAll()
        heldModifiers.removeAll()
        latchedModifiers.removeAll()
        usedModifiers.removeAll()
        unlatchOnRelease.removeAll()
        fnHeld = false
        fnLatched = false
        send?([.releaseAll])
        refresh()
    }

    private func refresh() {
        let down = Set(touchKeys.values)
        for (index, cap) in caps.enumerated() {
            var latched = false
            switch specs[index].kind {
            case .modifier(let code): latched = latchedModifiers.contains(code)
            case .fn: latched = fnLatched
            case .caps: latched = capsOn
            default: break
            }
            cap.update(down: down.contains(index), latched: latched, fnLayer: fnActive)
        }
    }
}

final class KeyCapView: UIView {
    static let normalColor = UIColor(red: 0.035, green: 0.035, blue: 0.04, alpha: 1)
    static let downColor = UIColor(white: 0.22, alpha: 1)
    static let latchedColor = UIColor(white: 0.26, alpha: 1)
    private static let legend = UIColor(white: 1, alpha: 0.93)

    private let spec: KeySpec
    private let mainLabel = UILabel()
    private let topLabel = UILabel()
    private let icon = UIImageView()
    private let capsLight = UIView()
    private var state: (down: Bool, latched: Bool, fnLayer: Bool) = (false, false, false)

    init(spec: KeySpec) {
        self.spec = spec
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        backgroundColor = KeyCapView.normalColor
        layer.cornerCurve = .continuous
        layer.borderWidth = 0.5
        mainLabel.textColor = KeyCapView.legend
        mainLabel.adjustsFontSizeToFitWidth = true
        mainLabel.minimumScaleFactor = 0.6
        topLabel.textColor = KeyCapView.legend
        icon.contentMode = .scaleAspectFit
        icon.tintColor = KeyCapView.legend
        capsLight.layer.cornerRadius = 1.5
        addSubview(mainLabel)
        addSubview(topLabel)
        addSubview(icon)
        if spec.kind == .caps { addSubview(capsLight) }
        apply()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(down: Bool, latched: Bool, fnLayer: Bool) {
        guard state != (down, latched, fnLayer) else { return }
        state = (down, latched, fnLayer)
        apply()
    }

    private func apply() {
        backgroundColor = state.down ? KeyCapView.downColor : state.latched ? KeyCapView.latchedColor : KeyCapView.normalColor
        layer.borderColor = UIColor(white: 1, alpha: state.latched ? 0.5 : 0.07).cgColor
        capsLight.backgroundColor = state.latched ? UIColor(red: 0.3, green: 0.95, blue: 0.45, alpha: 1) : UIColor(white: 1, alpha: 0.14)
        setNeedsLayout()
    }

    private func place(_ text: String?, in label: UILabel, size: CGFloat, align: NSTextAlignment, frame: CGRect) {
        label.text = text
        label.font = .systemFont(ofSize: size, weight: .regular)
        label.textAlignment = align
        label.frame = frame
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let h = bounds.height, w = bounds.width
        layer.cornerRadius = min(6, h * 0.14)
        icon.isHidden = true
        mainLabel.alpha = 1
        mainLabel.isHidden = false
        topLabel.frame = .zero
        topLabel.text = nil
        capsLight.frame = CGRect(x: 6, y: 6, width: 3, height: 3)

        if case .function(let n) = spec.kind {
            let symbol = UIImage(systemName: FunctionKey.all[n - 1].symbol)
            icon.image = symbol
            if h >= 24 {
                // Icon above, F-number below, as printed on the real keys.
                let side = h * 0.42
                icon.isHidden = false
                icon.alpha = state.fnLayer ? 0.4 : 1
                icon.frame = CGRect(x: w / 2 - side / 2, y: h * 0.13, width: side, height: side)
                mainLabel.alpha = state.fnLayer ? 1 : 0.6
                place("F\(n)", in: mainLabel, size: min(h * 0.22, 8.5), align: .center, frame: CGRect(x: 0, y: h * 0.62, width: w, height: h * 0.3))
            } else if state.fnLayer {
                place("F\(n)", in: mainLabel, size: h * 0.42, align: .center, frame: bounds)
            } else {
                let side = min(w, h) * 0.56
                icon.isHidden = false
                icon.alpha = 1
                icon.frame = CGRect(x: w / 2 - side / 2, y: h / 2 - side / 2, width: side, height: side)
                mainLabel.isHidden = true
            }
            return
        }

        let roomy = w >= 40
        let small = min(h * 0.21, 9.5)
        if spec.kind == .fn, roomy {
            icon.isHidden = false
            icon.alpha = 1
            icon.image = UIImage(systemName: "globe")
            let side = h * 0.26
            icon.frame = CGRect(x: 6, y: h * 0.62, width: side, height: side)
            place("fn", in: mainLabel, size: small, align: .right, frame: CGRect(x: 0, y: h * 0.1, width: w - 6, height: h * 0.3))
            return
        }
        if let word = spec.word, roomy || spec.kind == .caps || w >= 34 && spec.align != .center {
            if spec.align == .center {
                // control, option, command: symbol in the corner, name along the bottom.
                place(spec.label, in: topLabel, size: small + 1.5, align: .right, frame: CGRect(x: 0, y: h * 0.09, width: w - 6, height: h * 0.32))
                place(word, in: mainLabel, size: small, align: .center, frame: CGRect(x: 2, y: h * 0.62, width: w - 4, height: h * 0.3))
            } else {
                place(word, in: mainLabel, size: small, align: spec.align == .left ? .left : .right,
                      frame: CGRect(x: 7, y: h * 0.62, width: w - 14, height: h * 0.3))
            }
            return
        }
        if let top = spec.top {
            let size = min(h * 0.27, 12.5)
            place(top, in: topLabel, size: size, align: .center, frame: CGRect(x: 0, y: h * 0.12, width: w, height: h * 0.36))
            place(spec.label, in: mainLabel, size: size, align: .center, frame: CGRect(x: 0, y: h * 0.5, width: w, height: h * 0.38))
            return
        }
        let text = spec.label
        let size: CGFloat
        if spec.slot != .full { size = min(h * 0.55, 9) } else if text.count > 1 { size = min(h * 0.32, 11.5) } else { size = min(h * 0.38, 17) }
        place(text, in: mainLabel, size: size, align: .center, frame: bounds.insetBy(dx: 2, dy: 0))
    }
}
