import UIKit

/// The hidden text view that owns the iOS keyboard (autocorrect, predictions, swipe typing, dictation).
/// Whatever its text becomes is typed on the Mac through `TextSync`.
final class TypingProxy: UITextView, UITextViewDelegate {
    var send: (([InputEvent]) -> Void)?
    let bar = ModifierBar()

    private var sync = TextSync()
    private var applying = false

    var autocorrect: Bool {
        didSet { UserDefaults.standard.set(autocorrect, forKey: "autocorrect"); applyTraits(reload: true) }
    }
    var autoCapitalize: Bool {
        didSet { UserDefaults.standard.set(autoCapitalize, forKey: "autoCapitalize"); applyTraits(reload: true) }
    }

    init() {
        let d = UserDefaults.standard
        autocorrect = d.object(forKey: "autocorrect") == nil ? true : d.bool(forKey: "autocorrect")
        autoCapitalize = d.object(forKey: "autoCapitalize") == nil ? true : d.bool(forKey: "autoCapitalize")
        super.init(frame: CGRect(x: 0, y: 0, width: 1, height: 1), textContainer: nil)
        delegate = self
        alpha = 0.01
        backgroundColor = .clear
        textColor = .clear
        tintColor = .clear
        isScrollEnabled = false
        scrollsToTop = false
        keyboardAppearance = .dark
        smartQuotesType = .no
        smartDashesType = .no
        smartInsertDeleteType = .no
        accessibilityIdentifier = "typing-proxy"
        // The bar is not an input accessory: the session view lays it out itself, so it never lands
        // on the top screen over the Mac picture, and it stays when the iOS keyboard goes away.
        // After the touch on the bar is done, so reloading the keyboard never cancels it.
        bar.onLatchesChanged = { [weak self] in DispatchQueue.main.async { self?.applyTraits(reload: true) } }
        applyTraits(reload: false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// While a Mac modifier is latched, auto-capitalization is off so Command-C is not Command-Shift-C.
    private func applyTraits(reload: Bool) {
        let correction: UITextAutocorrectionType = autocorrect ? .yes : .no
        let spelling: UITextSpellCheckingType = autocorrect ? .yes : .no
        let caps: UITextAutocapitalizationType = autoCapitalize && !bar.hasLatches ? .sentences : .none
        guard correction != autocorrectionType || spelling != spellCheckingType || caps != autocapitalizationType else { return }
        autocorrectionType = correction
        spellCheckingType = spelling
        autocapitalizationType = caps
        if reload, isFirstResponder {
            reloadInputViews()
            // The keyboard works out its automatic shift again only when told the text changed.
            inputDelegate?.textWillChange(self)
            inputDelegate?.textDidChange(self)
        }
    }

    /// Called after every `reset()`, so the drawn phone keyboard forgets its state with the buffer.
    var onReset: (() -> Void)?

    /// Clear the field and forget what was sent: the Mac's cursor or focus may have moved.
    func reset() {
        sync.reset()
        setField("")
        onReset?()
    }

    private func setField(_ value: String) {
        guard text != value else { return }
        applying = true
        text = value
        applying = false
    }

    // MARK: Typing

    func textViewDidChange(_ textView: UITextView) {
        guard !applying, markedTextRange == nil else { return }
        typed(text ?? "")
    }

    /// The field now says `new`: from the iOS keyboard (already in the field), or from the drawn phone
    /// keyboard, which goes through here so latched shortcuts, the sync and trimming behave the same.
    func typed(_ new: String) {
        setField(new)
        if bar.hasLatches {
            let old = sync.sent
            if new.count == old.count + 1, new.starts(with: old), let ch = new.last, let key = KeyCodes.key(for: ch) {
                // One character with Command, Control or Option latched: a shortcut, not text.
                var events: [InputEvent] = []
                if key.shift { events.append(.key(code: KeyCodes.shift, down: true, isRepeat: false)) }
                events.append(.key(code: key.code, down: true, isRepeat: false))
                events.append(.key(code: key.code, down: false, isRepeat: false))
                if key.shift { events.append(.key(code: KeyCodes.shift, down: false, isRepeat: false)) }
                send?(events)
                Haptics.shared.play(.key)
                setField(old)
                bar.consumeLatches()
                return
            }
            // Anything else goes through as usual, still with the modifier held for it.
            syncText(new)
            bar.consumeLatches()
            return
        }
        syncText(new)
    }

    private func syncText(_ new: String) {
        let steps = sync.update(to: new)
        if sync.needsReset {
            reset()
            return
        }
        var events: [InputEvent] = []
        var sawReturn = false
        for step in steps {
            switch step {
            case .backspace(let count):
                for _ in 0..<count {
                    events.append(.key(code: 51, down: true, isRepeat: false))
                    events.append(.key(code: 51, down: false, isRepeat: false))
                }
            case .text(let s):
                events.append(.text(s))
            case .returnKey:
                sawReturn = true
                events.append(.key(code: 36, down: true, isRepeat: false))
                events.append(.key(code: 36, down: false, isRepeat: false))
            }
        }
        if !events.isEmpty {
            send?(events)
            Haptics.shared.play(.key)
        }
        if sawReturn {
            setField(sync.sent) // what follows the last line break, usually nothing
        } else if sync.shouldTrim(new) {
            let kept = TextSync.trimmed(new)
            setField(kept)
            sync.adopt(kept)
        }
    }

    /// Delete keeps working past the start of the buffer.
    override func deleteBackward() {
        if (text ?? "").isEmpty, markedTextRange == nil {
            send?([.key(code: 51, down: true, isRepeat: false), .key(code: 51, down: false, isRepeat: false)])
            Haptics.shared.play(.key)
            bar.consumeLatches()
            return
        }
        super.deleteBackward()
    }

    // The field is never seen, so it never scrolls anything into view.
    override func scrollRectToVisible(_ rect: CGRect, animated: Bool) {}
}

/// The Space Black row above the iOS keyboard: esc, tab, the Mac modifiers, arrows,
/// the trackpad key, a key back to the Mac keyboard, and the menu.
final class ModifierBar: UIView {
    var send: (([InputEvent]) -> Void)?
    /// A key that may move the Mac's cursor or focus was pressed.
    var onKey: (() -> Void)?
    var onMacKeyboard: (() -> Void)?
    /// The trackpad key: hide the iOS keyboard and make the whole bottom a trackpad, or bring it back.
    var onPad: (() -> Void)?
    var onLatchesChanged: (() -> Void)?
    let menuButton = UIButton(type: .system)
    let macKeyboardButton = UIButton(type: .system)
    let padButton = UIButton(type: .system)
    /// Lit like a latched modifier while the bottom is all trackpad.
    var padOn = false {
        didSet { if padOn != oldValue { stylePad() } }
    }

    /// The key back to the Mac keyboard; hidden in landscape, which always uses the bar.
    var showsMacKeyboard = true {
        didSet {
            guard showsMacKeyboard != oldValue else { return }
            macKeyboardButton.isHidden = !showsMacKeyboard
            setNeedsLayout()
        }
    }

    static let height: CGFloat = 46

    private struct Item {
        let id: String
        let spec: KeySpec
        let spoken: String
    }

    private let items: [Item] = [
        Item(id: "bar-esc", spec: KeySpec(kind: .key(53), label: "esc"), spoken: "Escape"),
        Item(id: "bar-tab", spec: KeySpec(kind: .key(48), label: "tab"), spoken: "Tab"),
        Item(id: "bar-control", spec: KeySpec(kind: .modifier(59), label: "⌃", word: "control"), spoken: "Control"),
        Item(id: "bar-option", spec: KeySpec(kind: .modifier(58), label: "⌥", word: "option"), spoken: "Option"),
        Item(id: "bar-command", spec: KeySpec(kind: .modifier(55), label: "⌘", word: "command"), spoken: "Command"),
        Item(id: "bar-left", spec: KeySpec(kind: .key(123), label: "◀"), spoken: "Left arrow"),
        Item(id: "bar-down", spec: KeySpec(kind: .key(125), label: "▼"), spoken: "Down arrow"),
        Item(id: "bar-up", spec: KeySpec(kind: .key(126), label: "▲"), spoken: "Up arrow"),
        Item(id: "bar-right", spec: KeySpec(kind: .key(124), label: "▶"), spoken: "Right arrow"),
    ]
    private var caps: [KeyCapView] = []
    private var touchKeys: [UITouch: Int] = [:]
    private var sentCodes: [Int: UInt16] = [:]
    private var latched = Set<UInt16>()
    private let repeater = KeyRepeater()

    var hasLatches: Bool { !latched.isEmpty }

    init() {
        super.init(frame: CGRect(x: 0, y: 0, width: 0, height: ModifierBar.height))
        autoresizingMask = .flexibleWidth
        isMultipleTouchEnabled = true
        backgroundColor = UIColor(red: 0.075, green: 0.075, blue: 0.082, alpha: 1) // the keyboard well
        for item in items {
            let cap = KeyCapView(spec: item.spec)
            cap.isAccessibilityElement = true
            cap.accessibilityTraits = .keyboardKey
            cap.accessibilityIdentifier = item.id
            cap.accessibilityLabel = item.spoken
            caps.append(cap)
            addSubview(cap)
        }
        let padSymbol = UIImage(systemName: "rectangle.and.hand.point.up.left") ?? UIImage(systemName: "hand.point.up.left")
        padButton.setImage(padSymbol, for: .normal)
        padButton.tintColor = UIColor(white: 1, alpha: 0.93)
        padButton.layer.borderWidth = 0.5
        padButton.layer.cornerCurve = .continuous
        padButton.accessibilityIdentifier = "bar-pad"
        padButton.accessibilityLabel = "Trackpad"
        padButton.addAction(UIAction { [weak self] _ in
            Haptics.shared.play(.key)
            self?.onPad?()
        }, for: .touchUpInside)
        stylePad()
        addSubview(padButton)
        macKeyboardButton.setImage(UIImage(systemName: "keyboard"), for: .normal)
        macKeyboardButton.tintColor = UIColor(white: 1, alpha: 0.93)
        macKeyboardButton.backgroundColor = KeyCapView.normalColor
        macKeyboardButton.layer.borderWidth = 0.5
        macKeyboardButton.layer.borderColor = UIColor(white: 1, alpha: 0.07).cgColor
        macKeyboardButton.layer.cornerCurve = .continuous
        macKeyboardButton.accessibilityIdentifier = "bar-mac-keyboard"
        macKeyboardButton.accessibilityLabel = "Mac keyboard"
        macKeyboardButton.addAction(UIAction { [weak self] _ in
            Haptics.shared.play(.key)
            self?.onMacKeyboard?()
        }, for: .touchUpInside)
        addSubview(macKeyboardButton)
        // The Touch ID key, as on the Mac keyboard.
        menuButton.setImage(UIImage(systemName: "touchid"), for: .normal)
        menuButton.tintColor = UIColor(white: 1, alpha: 0.32)
        menuButton.backgroundColor = UIColor(white: 0.1, alpha: 1)
        menuButton.layer.cornerCurve = .continuous
        menuButton.showsMenuAsPrimaryAction = true
        menuButton.accessibilityIdentifier = "bar-menu"
        menuButton.accessibilityLabel = "Menu"
        addSubview(menuButton)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: CGSize { CGSize(width: UIView.noIntrinsicMetric, height: ModifierBar.height) }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Full width, like the iOS keyboard under it (the cover screen reports a side inset the keyboard ignores).
        let pad: CGFloat = 4
        let count = CGFloat(items.count + (showsMacKeyboard ? 3 : 2))
        let left = pad
        let slot = (bounds.width - pad * 2) / count
        let gap = max(3, min(slot * 0.1, 6))
        let h = ModifierBar.height - pad * 2
        func frame(_ i: Int) -> CGRect {
            CGRect(x: left + CGFloat(i) * slot, y: pad, width: slot, height: h).insetBy(dx: gap / 2, dy: gap / 2)
        }
        for (i, cap) in caps.enumerated() { cap.frame = frame(i) }
        padButton.frame = frame(items.count)
        if showsMacKeyboard { macKeyboardButton.frame = frame(items.count + 1) }
        menuButton.frame = frame(items.count + (showsMacKeyboard ? 2 : 1))
        for button in [padButton, macKeyboardButton, menuButton] {
            button.layer.cornerRadius = min(6, button.bounds.height * 0.14)
        }
    }

    private func stylePad() {
        padButton.backgroundColor = padOn ? KeyCapView.latchedColor : KeyCapView.normalColor
        padButton.layer.borderColor = UIColor(white: 1, alpha: padOn ? 0.5 : 0.07).cgColor
        padButton.accessibilityTraits = padOn ? [.button, .selected] : .button
    }

    // MARK: Touches

    private func index(at point: CGPoint) -> Int? {
        caps.firstIndex { $0.frame.insetBy(dx: -3, dy: -4).contains(point) }
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            guard let i = index(at: touch.location(in: self)), !touchKeys.values.contains(i) else { continue }
            touchKeys[touch] = i
            press(i)
        }
        refresh()
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        var released = false
        for touch in touches {
            guard let i = touchKeys.removeValue(forKey: touch) else { continue }
            released = release(i) || released
        }
        refresh()
        if released { onKey?() }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        touchesEnded(touches, with: event)
    }

    private func press(_ i: Int) {
        Haptics.shared.play(.key)
        switch items[i].spec.kind {
        case .modifier(let code):
            // Tap to hold for the next key or click; tap again to let go.
            if latched.remove(code) != nil {
                send?([.key(code: code, down: false, isRepeat: false)])
            } else {
                latched.insert(code)
                send?([.key(code: code, down: true, isRepeat: false)])
            }
            onLatchesChanged?()
        case .key(let code):
            sentCodes[i] = code
            send?([.key(code: code, down: true, isRepeat: false)])
            if [123, 124, 125, 126].contains(code) {
                repeater.start(i) { [weak self] in self?.send?([.key(code: code, down: true, isRepeat: true)]) }
            }
        default:
            break
        }
    }

    /// True when a key (not a modifier) went up.
    private func release(_ i: Int) -> Bool {
        guard case .key = items[i].spec.kind else { return false }
        repeater.stop(i)
        if let code = sentCodes.removeValue(forKey: i) {
            send?([.key(code: code, down: false, isRepeat: false)])
        }
        consumeLatches()
        return true
    }

    /// Latched modifiers apply to one key or one click, then let go.
    func consumeLatches() {
        guard !latched.isEmpty else { return }
        send?(latched.map { .key(code: $0, down: false, isRepeat: false) })
        latched.removeAll()
        refresh()
        onLatchesChanged?()
    }

    /// Let go of everything, for leaving the mode, the app going away, or the link dropping.
    func releaseEverything() {
        repeater.stopAll()
        var events: [InputEvent] = sentCodes.values.map { .key(code: $0, down: false, isRepeat: false) }
        events += latched.map { .key(code: $0, down: false, isRepeat: false) }
        let hadLatches = !latched.isEmpty
        sentCodes.removeAll()
        touchKeys.removeAll()
        latched.removeAll()
        if !events.isEmpty { send?(events) }
        refresh()
        if hadLatches { onLatchesChanged?() }
    }

    private func refresh() {
        let down = Set(touchKeys.values)
        for (i, cap) in caps.enumerated() {
            var isLatched = false
            if case .modifier(let code) = items[i].spec.kind { isLatched = latched.contains(code) }
            cap.update(down: down.contains(i), latched: isLatched, fnLayer: false)
        }
    }
}
