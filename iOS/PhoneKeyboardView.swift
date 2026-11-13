import UIKit

/// The iOS dark keyboard, drawn by the app. Used only in the tall hold iOS refuses to turn to, where the
/// app turns its own view half way round and the system keyboard (drawn by another process) cannot follow.
/// It owns no text: keys go out through the closures and `PhoneTyping` does the rest.
final class PhoneKeyboardView: UIView {
    struct Suggestion: Equatable {
        var text: String
        /// What a space will apply; drawn with a soft rounded highlight.
        var isDefault = false
    }

    enum ShiftState { case off, once, locked }
    enum Plane { case letters, numbers, symbols }

    var onInsert: ((String) -> Void)?
    /// Delete, with true for the held key's repeats.
    var onDelete: ((_ repeating: Bool) -> Void)?
    /// The held delete key stopped repeating (or was let go).
    var onDeleteEnded: (() -> Void)?
    var onReturn: (() -> Void)?
    var onSuggestion: ((Int) -> Void)?

    var suggestions: [Suggestion] = [] {
        didSet { if suggestions != oldValue { updateStrip() } }
    }
    /// The shift key sets it; auto-capitals go through `setAutoShift`.
    private(set) var shiftState: ShiftState = .off {
        didSet { if shiftState != oldValue { refreshCaps() } }
    }
    /// The one-shot shift came from auto-capitals, not from a tap on the shift key.
    private var shiftIsAuto = false

    /// Auto-capitals: turns an automatic one-shot shift on or off. Caps lock and a shift the user tapped stay.
    func setAutoShift(_ on: Bool) {
        if shiftState == .locked || (shiftState == .once && !shiftIsAuto) { return }
        shiftState = on ? .once : .off
        shiftIsAuto = on
    }
    /// Room left under the last row, at the bottom of the view.
    var bottomPadding: CGFloat = 8 {
        didSet { if bottomPadding != oldValue { setNeedsLayout() } }
    }
    private(set) var plane: Plane = .letters

    /// The height to use when the system keyboard's own height for this width is not known.
    static func height(forWidth width: CGFloat) -> CGFloat {
        min(max(width * 0.547, 250), 366)
    }

    static let wellColor = UIColor(red: 0x1F / 255, green: 0x21 / 255, blue: 0x26 / 255, alpha: 1)
    static let keyColor = UIColor(red: 0x45 / 255, green: 0x46 / 255, blue: 0x4B / 255, alpha: 1)
    static let functionColor = UIColor(red: 0x37 / 255, green: 0x38 / 255, blue: 0x3D / 255, alpha: 1)
    static let downColor = UIColor(red: 0x6C / 255, green: 0x6D / 255, blue: 0x72 / 255, alpha: 1)

    fileprivate enum Kind: Equatable {
        case char(String), shift, delete, plane, symbols, space, ret
        var isFunction: Bool {
            switch self {
            case .char, .space: return false
            default: return true
            }
        }
    }

    private struct Key {
        let kind: Kind
        let width: CGFloat // in key pitches
    }

    private enum Target: Hashable {
        case key(row: Int, index: Int)
        case suggestion(Int)
        var isSuggestion: Bool {
            if case .suggestion = self { return true }
            return false
        }
    }

    private var rows: [[Key]] = []
    private var caps: [[PhoneKeyCap]] = []
    private var keyFrames: [[CGRect]] = []
    private let stripSlots = (0..<3).map { _ in PhoneSuggestionSlot() }
    private let dividers = (0..<2).map { _ in UIView() }
    private var stripHeight: CGFloat = 44
    private var keysTop: CGFloat = 44
    private var pitch: CGFloat = 50

    private var targets: [UITouch: Target] = [:]
    private var stripTouches = Set<UITouch>()
    private var deleteTouch: UITouch?
    private let repeater = KeyRepeater()
    private var lastShiftTap: TimeInterval = 0
    /// A number or symbol was typed on the current plane: the next space goes back to letters, as on iOS.
    private var typedOnPlane = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        backgroundColor = PhoneKeyboardView.wellColor
        layer.cornerCurve = .continuous
        layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        accessibilityIdentifier = "phone-keyboard"
        for divider in dividers {
            divider.backgroundColor = UIColor(white: 1, alpha: 0.16)
            divider.isUserInteractionEnabled = false
            addSubview(divider)
        }
        for (i, slot) in stripSlots.enumerated() {
            slot.accessibilityIdentifier = "pk-suggest-\(i)"
            addSubview(slot)
        }
        buildKeys()
        updateStrip()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: Keys

    private static func rows(for plane: Plane) -> [[Key]] {
        func chars(_ s: String, width: CGFloat = 1) -> [Key] { s.map { Key(kind: .char(String($0)), width: width) } }
        let bottom = [Key(kind: .plane, width: 1.5), Key(kind: .space, width: 7), Key(kind: .ret, width: 1.5)]
        let punctuation = chars(".,?!'", width: 1.4)
        switch plane {
        case .letters:
            return [chars("qwertyuiop"), chars("asdfghjkl"),
                    [Key(kind: .shift, width: 1.5)] + chars("zxcvbnm") + [Key(kind: .delete, width: 1.5)], bottom]
        case .numbers:
            return [chars("1234567890"), chars("-/:;()$&@\""),
                    [Key(kind: .symbols, width: 1.5)] + punctuation + [Key(kind: .delete, width: 1.5)], bottom]
        case .symbols:
            return [chars("[]{}#%^*+="), chars("_\\|~<>€£¥•"),
                    [Key(kind: .symbols, width: 1.5)] + punctuation + [Key(kind: .delete, width: 1.5)], bottom]
        }
    }

    private func buildKeys() {
        caps.joined().forEach { $0.removeFromSuperview() }
        rows = PhoneKeyboardView.rows(for: plane)
        caps = rows.map { row in
            row.map { key in
                let cap = PhoneKeyCap(isFunction: key.kind.isFunction)
                cap.accessibilityIdentifier = id(for: key.kind)
                addSubview(cap)
                return cap
            }
        }
        keyFrames = rows.map { Array(repeating: .zero, count: $0.count) }
        refreshCaps()
        setNeedsLayout()
    }

    private func id(for kind: Kind) -> String {
        switch kind {
        case .char(let c): return "pk-\(c.lowercased())"
        case .shift: return "pk-shift"
        case .delete: return "pk-delete"
        case .plane: return "pk-plane"
        case .symbols: return "pk-symbols"
        case .space: return "pk-space"
        case .ret: return "pk-return"
        }
    }

    private func setPlane(_ new: Plane) {
        guard new != plane else { return }
        plane = new
        typedOnPlane = false
        // Touches still on the old keys have nothing left to press.
        targets = targets.filter { $0.key == deleteTouch || stripTouches.contains($0.key) }
        buildKeys()
        layoutIfNeeded()
    }

    /// Labels follow the plane and shift; highlights follow the fingers.
    private func refreshCaps() {
        let down = Set(targets.values)
        let upper = shiftState != .off
        for (r, row) in rows.enumerated() {
            for (i, key) in row.enumerated() {
                let cap = caps[r][i]
                switch key.kind {
                case .char(let c):
                    let shown = plane == .letters && upper ? c.uppercased() : c
                    cap.setText(shown, spoken: shown)
                case .shift:
                    let symbol: String
                    switch shiftState {
                    case .off: symbol = "shift"
                    case .once: symbol = "shift.fill"
                    case .locked: symbol = "capslock.fill"
                    }
                    cap.setSymbol(symbol, fallback: "shift", spoken: shiftState == .locked ? "caps lock" : "shift")
                case .delete:
                    cap.setSymbol("delete.left", fallback: "del", spoken: "delete")
                case .plane:
                    cap.setText(plane == .letters ? "123" : "ABC", spoken: plane == .letters ? "numbers" : "letters")
                case .symbols:
                    cap.setText(plane == .numbers ? "#+=" : "123", spoken: plane == .numbers ? "symbols" : "numbers")
                case .space:
                    cap.setText("", spoken: "space")
                case .ret:
                    cap.setSymbol("return.left", fallback: "return", spoken: "return")
                }
                cap.isDown = down.contains(.key(row: r, index: i))
            }
        }
        for (i, slot) in stripSlots.enumerated() { slot.isDown = down.contains(.suggestion(i)) }
    }

    private func updateStrip() {
        for (i, slot) in stripSlots.enumerated() {
            let s = i < suggestions.count ? suggestions[i] : Suggestion(text: "")
            slot.set(text: s.text, highlighted: s.isDefault)
        }
        // iOS drops the divider next to a highlighted suggestion.
        for (i, divider) in dividers.enumerated() {
            let lit = [i, i + 1].contains { $0 < suggestions.count && suggestions[$0].isDefault }
            divider.isHidden = lit
        }
    }

    // MARK: Layout

    override func layoutSubviews() {
        super.layoutSubviews()
        let w = bounds.width, h = bounds.height
        guard w > 0, h > 0 else { return }
        layer.cornerRadius = min(28, w * 0.055)
        stripHeight = min(max(w * 0.0985, 40), 50)
        keysTop = stripHeight
        let pad = max(bottomPadding, 4)
        pitch = max(min(w * 0.12, (h - stripHeight - pad) / 4), 20)
        let side = w * 0.0075
        let unit = (w - side * 2) / 10
        let hGap = unit * 0.14
        let vGap = pitch * 0.2
        let keyHeight = pitch - vGap
        let radius = min(max(keyHeight * 0.2, 6), 9.5)
        let letterSize = min(keyHeight * 0.58, unit * 0.62, 30)

        for (r, row) in rows.enumerated() {
            let total = row.reduce(0) { $0 + $1.width }
            var x = side + (10 - total) / 2 * unit
            let y = keysTop + CGFloat(r) * pitch
            for (i, key) in row.enumerated() {
                let slot = CGRect(x: x, y: y, width: key.width * unit, height: pitch)
                var frame = slot.insetBy(dx: hGap / 2, dy: vGap / 2)
                if r == 2, key.kind.isFunction {
                    // Shift, #+= and delete stand off from the letters, as on iOS.
                    let width = slot.width - hGap - unit * 0.19
                    frame.origin.x = i == 0 ? slot.minX + hGap / 2 : slot.maxX - hGap / 2 - width
                    frame.size.width = width
                }
                keyFrames[r][i] = frame
                let cap = caps[r][i]
                cap.frame = frame
                cap.layer.cornerRadius = radius
                if case .char = key.kind { cap.fontSize = letterSize } else { cap.fontSize = min(keyHeight * 0.48, 22) }
                x += slot.width
            }
        }

        let third = w / 3
        for (i, slot) in stripSlots.enumerated() {
            slot.frame = CGRect(x: third * CGFloat(i), y: 0, width: third, height: stripHeight).insetBy(dx: 4, dy: 5)
            slot.fontSize = min(max(stripHeight * 0.4, 15), 19)
        }
        for (i, divider) in dividers.enumerated() {
            let lineHeight = stripHeight * 0.42
            divider.frame = CGRect(x: third * CGFloat(i + 1) - 0.5, y: (stripHeight - lineHeight) / 2,
                                   width: 1 / max(traitCollection.displayScale, 1), height: lineHeight)
        }
    }

    // MARK: Touches

    /// A touch belongs to the nearest key in its row; rows and keys leave no dead gaps between them.
    private func target(at point: CGPoint, inStrip: Bool) -> Target? {
        if inStrip {
            let i = Int(point.x / max(bounds.width / 3, 1))
            return .suggestion(min(max(i, 0), 2))
        }
        guard !rows.isEmpty else { return nil }
        let r = min(max(Int(floor((point.y - keysTop) / max(pitch, 1))), 0), rows.count - 1)
        var best: (Int, CGFloat)?
        for (i, frame) in keyFrames[r].enumerated() {
            let d = max(frame.minX - point.x, 0, point.x - frame.maxX)
            if d < (best?.1 ?? .greatestFiniteMagnitude) { best = (i, d) }
        }
        return best.map { .key(row: r, index: $0.0) }
    }

    private func kind(of target: Target) -> Kind? {
        guard case .key(let r, let i) = target, r < rows.count, i < rows[r].count else { return nil }
        return rows[r][i].kind
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            // Rollover: a second finger landing commits the first at once.
            for (other, held) in targets where other != touch {
                targets[other] = nil
                stripTouches.remove(other)
                if other == deleteTouch {
                    endDelete()
                } else {
                    commit(held)
                }
            }
            let point = touch.location(in: self)
            let inStrip = point.y < keysTop
            guard let t = target(at: point, inStrip: inStrip) else { continue }
            targets[touch] = t
            if inStrip { stripTouches.insert(touch) }
            if kind(of: t) == .delete {
                // Delete acts on the way down and repeats while held. Its tick comes from the typing path.
                deleteTouch = touch
                lastShiftTap = 0
                onDelete?(false)
                repeater.start(0) { [weak self] in self?.onDelete?(true) }
            }
        }
        refreshCaps()
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches where targets[touch] != nil && touch != deleteTouch {
            if let t = target(at: touch.location(in: self), inStrip: stripTouches.contains(touch)) { targets[touch] = t }
        }
        refreshCaps()
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            stripTouches.remove(touch)
            guard let t = targets.removeValue(forKey: touch) else { continue }
            if touch == deleteTouch {
                endDelete()
                continue
            }
            // Commits at the key under the finger now, not where it landed.
            if let now = target(at: touch.location(in: self), inStrip: t.isSuggestion) { commit(now) } else { commit(t) }
        }
        refreshCaps()
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            stripTouches.remove(touch)
            targets[touch] = nil
            if touch == deleteTouch { endDelete() }
        }
        refreshCaps()
    }

    /// The delete key is no longer held: stop its repeat and let the strip catch up.
    private func endDelete() {
        repeater.stop(0)
        deleteTouch = nil
        onDeleteEnded?()
    }

    /// Forget every finger, for the app going away or the keyboard being hidden.
    func releaseEverything() {
        repeater.stopAll()
        targets.removeAll()
        stripTouches.removeAll()
        let wasDeleting = deleteTouch != nil
        deleteTouch = nil
        if wasDeleting { onDeleteEnded?() }
        refreshCaps()
    }

    /// Only shift and the plane keys tick here; typing, delete, return and suggestions tick once
    /// from the typing path (`TypingProxy`), when something goes to the Mac.
    private func commit(_ target: Target) {
        if case .suggestion(let i) = target {
            lastShiftTap = 0
            if i < suggestions.count, !suggestions[i].text.isEmpty { onSuggestion?(i) }
            return
        }
        guard let kind = kind(of: target) else { return }
        // Shift, another key, shift is not a double tap.
        if kind != .shift { lastShiftTap = 0 }
        switch kind {
        case .char(let c):
            let text = plane == .letters && shiftState != .off ? c.uppercased() : c
            if shiftState == .once { shiftState = .off }
            if plane != .letters { typedOnPlane = true }
            onInsert?(text)
            // An apostrophe goes back to letters, as on iOS.
            if c == "'", plane != .letters { setPlane(.letters) }
        case .space:
            let back = plane != .letters && typedOnPlane
            onInsert?(" ")
            if back { setPlane(.letters) }
        case .ret:
            onReturn?()
        case .shift:
            Haptics.shared.play(.key)
            let now = ProcessInfo.processInfo.systemUptime
            if shiftState == .locked {
                shiftState = .off
            } else if now - lastShiftTap < 0.35 {
                shiftState = .locked
            } else {
                shiftState = shiftState == .off ? .once : .off
            }
            shiftIsAuto = false
            lastShiftTap = shiftState == .locked ? 0 : now
        case .plane:
            Haptics.shared.play(.key)
            setPlane(plane == .letters ? .numbers : .letters)
        case .symbols:
            Haptics.shared.play(.key)
            setPlane(plane == .numbers ? .symbols : .numbers)
        case .delete:
            break // acted on the way down
        }
    }
}

/// One key: a rounded cap with a letter or an SF symbol. Touches go to the keyboard, never to the key.
final class PhoneKeyCap: UIView {
    private let label = UILabel()
    private let icon = UIImageView()
    private let isFunction: Bool
    private var symbol: String?
    var isDown = false {
        didSet { if isDown != oldValue { applyColor() } }
    }
    var fontSize: CGFloat = 24 {
        didSet { if fontSize != oldValue { applyFont() } }
    }

    init(isFunction: Bool) {
        self.isFunction = isFunction
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        isAccessibilityElement = true
        accessibilityTraits = .keyboardKey
        layer.cornerCurve = .continuous
        label.textColor = .white
        label.textAlignment = .center
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.5
        icon.tintColor = .white
        icon.contentMode = .center
        addSubview(label)
        addSubview(icon)
        applyColor()
        applyFont()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setText(_ text: String, spoken: String) {
        symbol = nil
        icon.isHidden = true
        label.isHidden = false
        if label.text != text { label.text = text; applyFont() }
        accessibilityLabel = spoken
    }

    func setSymbol(_ name: String, fallback: String, spoken: String) {
        accessibilityLabel = spoken
        guard UIImage(systemName: name) != nil else { setText(fallback, spoken: spoken); return }
        label.isHidden = true
        icon.isHidden = false
        if symbol != name { symbol = name; applyFont() }
    }

    private func applyColor() {
        backgroundColor = isDown ? PhoneKeyboardView.downColor : isFunction ? PhoneKeyboardView.functionColor : PhoneKeyboardView.keyColor
    }

    private func applyFont() {
        let text = label.text ?? ""
        // Letters large like iOS; words such as 123 and ABC smaller.
        let size = text.count > 1 ? min(fontSize, 17) : fontSize
        label.font = .systemFont(ofSize: size, weight: .regular)
        if let symbol {
            let config = UIImage.SymbolConfiguration(pointSize: fontSize, weight: symbol.hasPrefix("shift") || symbol.hasPrefix("caps") ? .semibold : .medium)
            icon.image = UIImage(systemName: symbol, withConfiguration: config)
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Letters sit a touch high on iOS keys.
        label.frame = bounds.insetBy(dx: 2, dy: 0).offsetBy(dx: 0, dy: isFunction ? 0 : -1)
        icon.frame = bounds
    }
}

/// One place in the suggestion strip above the keys.
final class PhoneSuggestionSlot: UIView {
    private let label = UILabel()
    private let glow = UIView()
    var isDown = false {
        didSet { if isDown != oldValue { applyGlow() } }
    }
    var fontSize: CGFloat = 17 {
        didSet { if fontSize != oldValue { label.font = .systemFont(ofSize: fontSize) } }
    }
    private var highlighted = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isAccessibilityElement = true
        accessibilityTraits = .keyboardKey
        glow.layer.cornerCurve = .continuous
        glow.layer.cornerRadius = 9
        label.textColor = UIColor(white: 0.93, alpha: 1)
        label.textAlignment = .center
        label.font = .systemFont(ofSize: fontSize)
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.6
        label.lineBreakMode = .byTruncatingMiddle
        addSubview(glow)
        addSubview(label)
        applyGlow()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func set(text: String, highlighted: Bool) {
        label.text = text
        accessibilityLabel = text
        self.highlighted = highlighted
        applyGlow()
    }

    private func applyGlow() {
        let alpha: CGFloat = isDown ? 0.22 : highlighted ? 0.11 : 0
        glow.backgroundColor = UIColor(white: 1, alpha: alpha)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        glow.frame = bounds
        label.frame = bounds.insetBy(dx: 6, dy: 0)
    }
}
