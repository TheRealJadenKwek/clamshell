import UIKit
import Combine

/// A pretend Mac drawn inside the app, for trying Clamshell with no Mac set up ("Try the demo").
/// It stands in for `Client`: it takes the same input events the real host gets and shows what they
/// would do. No network, nothing stored; it lives until the demo ends.
final class DemoMac: MacLink {
    static let maxCharacters = 2000

    let phase: Client.Phase = .connected
    let latencyMs: Int? = nil
    var onCursor: ((CGPoint) -> Void)?
    let linkState: AnyPublisher<LinkState, Never>

    private(set) var text = ""
    /// Pointer tip, in the pretend Mac's points.
    private(set) var pointer = DemoLayout.pointerStart
    /// How far the typed text is scrolled up, in the pretend Mac's points.
    private(set) var scroll: CGFloat = 0
    /// Where the caret goes, relative to the typed text's top-left (unscrolled).
    private(set) var caret = CGRect.zero
    private var textHeight: CGFloat = 0

    private var modifiers = Set<UInt16>()
    private var capsLock = false
    private let views = NSHashTable<DemoMacView>.weakObjects()

    private let storage = NSTextStorage()
    private let layoutManager = NSLayoutManager()
    private let container: NSTextContainer

    /// US layout: (key code, shift) to the character it types.
    private static let characters: [UInt32: Character] = {
        var map: [UInt32: Character] = [:]
        for value in UInt8(33)...UInt8(126) {
            let ch = Character(UnicodeScalar(value))
            guard let key = KeyCodes.key(for: ch) else { continue }
            map[UInt32(key.code) << 1 | (key.shift ? 1 : 0)] = ch
        }
        return map
    }()

    init(text: String = "") {
        let ack = HelloAck(version: Wire.version, hostName: "Demo Mac",
                           displayPointWidth: DemoLayout.size.width, displayPointHeight: DemoLayout.size.height,
                           streamWidth: Int(DemoLayout.size.width), streamHeight: Int(DemoLayout.size.height),
                           codec: "hevc", canCapture: true, canControl: true, testPattern: false,
                           displayWidths: [1024, 1280, 1440, 1680], displayBaseWidth: 1440, displayNowWidth: 1440)
        linkState = Just((phase: .connected, problem: nil, ack: ack, status: HostStatus(canCapture: true, canControl: true)))
            .eraseToAnyPublisher()
        container = NSTextContainer(size: CGSize(width: DemoLayout.shared.textArea.width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        layoutManager.addTextContainer(container)
        storage.addLayoutManager(layoutManager)
        setText(text.replacingOccurrences(of: "\t", with: "    "))
    }

    /// A view showing this Mac; there can be more than one (layout renders make their own).
    func makeView() -> DemoMacView {
        let view = DemoMacView(mac: self)
        views.add(view)
        return view
    }

    // MARK: MacLink

    func send(_ event: InputEvent) { send([event]) }

    func send(_ events: [InputEvent]) {
        var changes = DemoChange()
        for event in events { apply(event, &changes) }
        if changes.pointer { onCursor?(CGPoint(x: pointer.x / DemoLayout.size.width, y: pointer.y / DemoLayout.size.height)) }
        guard changes.text || changes.scroll || changes.pointer || changes.click else { return }
        for view in views.allObjects { view.macChanged(changes) }
    }

    /// The display panel shows the choices; picking one only changes the panel's own "Looks like" line.
    func setDisplay(width: Int) {}
    func sendDeviceInfo(_ text: String) {}
    func reconnect() {}
    func recoverVideo() {}

    // MARK: Input

    private func apply(_ event: InputEvent, _ changes: inout DemoChange) {
        switch event {
        case .moveRel(let dx, let dy):
            movePointer(to: CGPoint(x: pointer.x + CGFloat(dx), y: pointer.y + CGFloat(dy)), &changes)
        case .moveAbs(let x, let y):
            movePointer(to: CGPoint(x: CGFloat(x) * DemoLayout.size.width, y: CGFloat(y) * DemoLayout.size.height), &changes)
        case .button(_, let down, _):
            // A click on the window's red dot (or anywhere) only shows the ring.
            if down { changes.click = true }
        case .scroll(_, let dy):
            let maxScroll = max(textHeight - DemoLayout.shared.textArea.height, 0)
            guard maxScroll > 0 else { return }
            let next = min(max(scroll - CGFloat(dy), 0), maxScroll) // natural scrolling: fingers down shows earlier text
            if next != scroll {
                scroll = next
                changes.scroll = true
            }
        case .key(let code, let down, _):
            key(code, down: down, &changes)
        case .text(let s):
            insert(s.replacingOccurrences(of: "\t", with: "    "), &changes)
        case .releaseAll:
            modifiers.removeAll()
        case .media, .action:
            break
        }
    }

    private func movePointer(to p: CGPoint, _ changes: inout DemoChange) {
        let clamped = CGPoint(x: min(max(p.x, 0), DemoLayout.size.width), y: min(max(p.y, 0), DemoLayout.size.height))
        guard clamped != pointer else { return }
        pointer = clamped
        changes.pointer = true
    }

    private func key(_ code: UInt16, down: Bool, _ changes: inout DemoChange) {
        switch code {
        case 54, 55, 56, 58, 59, 60, 61, 62: // Command, Shift, Option, Control (both sides)
            if down { modifiers.insert(code) } else { modifiers.remove(code) }
            return
        case 57:
            if down { capsLock.toggle() }
            return
        default:
            break
        }
        guard down else { return }
        let command = !modifiers.isDisjoint(with: [54, 55])
        let option = !modifiers.isDisjoint(with: [58, 61])
        let control = !modifiers.isDisjoint(with: [59, 62])
        let shift = !modifiers.isDisjoint(with: [56, 60])
        switch code {
        case 51:
            if command { deleteLine(&changes) } else if option { deleteWord(&changes) } else { deleteCharacter(&changes) }
        case 36, 76:
            insert("\n", &changes)
        case 48:
            insert("    ", &changes)
        case 49:
            if !command && !control { insert(" ", &changes) }
        default:
            // Shortcuts type nothing; other keys (arrows, escape, F-keys) are ignored.
            guard !command, !control else { return }
            guard var ch = Self.characters[UInt32(code) << 1 | (shift ? 1 : 0)] else { return }
            if capsLock, ch.isLetter { ch = Character(ch.uppercased()) }
            insert(String(ch), &changes)
        }
    }

    // MARK: Text

    private func insert(_ s: String, _ changes: inout DemoChange) {
        guard !s.isEmpty else { return }
        setText(text + s)
        changes.text = true
    }

    private func deleteCharacter(_ changes: inout DemoChange) {
        guard !text.isEmpty else { return }
        setText(String(text.dropLast()))
        changes.text = true
    }

    /// Command-Backspace: to the start of the line (or the line break, when already there).
    private func deleteLine(_ changes: inout DemoChange) {
        guard !text.isEmpty else { return }
        if text.last == "\n" {
            setText(String(text.dropLast()))
        } else if let breakIndex = text.lastIndex(of: "\n") {
            setText(String(text[...breakIndex]))
        } else {
            setText("")
        }
        changes.text = true
    }

    /// Option-Backspace: the spaces before the caret, then the word before them.
    private func deleteWord(_ changes: inout DemoChange) {
        guard !text.isEmpty else { return }
        var chars = Array(text)
        let start = chars.count
        while let last = chars.last, last == " " { chars.removeLast() }
        while let last = chars.last, last.isLetter || last.isNumber || last == "'" || last == "\u{2019}" { chars.removeLast() }
        if chars.count == start { chars.removeLast() } // punctuation or a line break on its own
        setText(String(chars))
        changes.text = true
    }

    private func setText(_ new: String) {
        text = new.count > Self.maxCharacters ? String(new.suffix(Self.maxCharacters)) : new
        let attributes: [NSAttributedString.Key: Any] = [.font: DemoLayout.typedFont, .foregroundColor: UIColor.white]
        storage.setAttributedString(NSAttributedString(string: text, attributes: attributes))
        layoutManager.ensureLayout(for: container)
        textHeight = layoutManager.usedRect(for: container).height
        caret = caretRect()
        // Typing keeps the caret in sight.
        scroll = max(caret.maxY - DemoLayout.shared.textArea.height, 0)
    }

    private func caretRect() -> CGRect {
        let lineHeight = DemoLayout.typedFont.lineHeight
        let extra = layoutManager.extraLineFragmentRect
        let glyphs = layoutManager.numberOfGlyphs
        if glyphs == 0 || extra.height > 0 {
            return CGRect(x: extra.minX, y: extra.height > 0 ? extra.minY : 0, width: 2, height: lineHeight)
        }
        let last = glyphs - 1
        let line = layoutManager.lineFragmentRect(forGlyphAt: last, effectiveRange: nil)
        let glyph = layoutManager.boundingRect(forGlyphRange: NSRange(location: last, length: 1), in: container)
        let x = min(glyph.maxX, container.size.width - 2)
        return CGRect(x: x, y: line.minY + (line.height - lineHeight) / 2, width: 2, height: lineHeight)
    }

    /// Draws the typed text with its top-left at `origin` into the current context.
    func drawText(at origin: CGPoint) {
        let range = layoutManager.glyphRange(for: container)
        layoutManager.drawGlyphs(forGlyphRange: range, at: origin)
    }
}

struct DemoChange {
    var text = false
    var scroll = false
    var pointer = false
    var click = false
}

/// Where everything sits on the pretend Mac, in its own points (1440 x 900, 16:10).
struct DemoLayout {
    static let size = CGSize(width: 1440, height: 900)
    static let menuBarHeight: CGFloat = 27
    static let window = CGRect(x: (1440 - 893) / 2, y: (900 - 594) / 2, width: 893, height: 594)
    static let windowCorner: CGFloat = 12
    static let titleBarHeight: CGFloat = 40
    static let padding: CGFloat = 36
    static let pointerStart = CGPoint(x: 720, y: 450 + 46)

    static let menuFont = UIFont.systemFont(ofSize: 15)
    static let menuBoldFont = UIFont.systemFont(ofSize: 15, weight: .semibold)
    static let titleFont = UIFont.systemFont(ofSize: 15, weight: .semibold)
    static let headingFont = UIFont.systemFont(ofSize: 36, weight: .semibold)
    static let noteFont = UIFont.systemFont(ofSize: 18)
    static let typedFont = UIFont.systemFont(ofSize: 28)

    static let heading = "Welcome to Clamshell"
    static let notes = ["Type on your iPhone and it appears here.",
                        "Move the pointer with the trackpad. This is a demo; pair with your Mac to control the real thing."]

    let headingRect: CGRect
    let noteRects: [CGRect]
    /// The typed text's box inside the window body.
    let textArea: CGRect

    static let shared = DemoLayout()

    private init() {
        let left = Self.window.minX + Self.padding
        let width = Self.window.width - 2 * Self.padding
        var y = Self.window.minY + Self.titleBarHeight + 30
        headingRect = CGRect(x: left, y: y, width: width, height: ceil(Self.headingFont.lineHeight))
        y = headingRect.maxY + 10
        var rects: [CGRect] = []
        for note in Self.notes {
            let height = ceil((note as NSString).boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude),
                                                              options: [.usesLineFragmentOrigin, .usesFontLeading],
                                                              attributes: [.font: Self.noteFont], context: nil).height)
            rects.append(CGRect(x: left, y: y, width: width, height: height))
            y += height + 4
        }
        noteRects = rects
        y += 24
        textArea = CGRect(x: left, y: y, width: width, height: Self.window.maxY - 28 - y)
    }
}

/// Draws a `DemoMac`: the picture with CoreGraphics (again only when something changes), the pointer,
/// the caret and the click ring as layers.
final class DemoMacView: UIView {
    private let mac: DemoMac
    private let pointerLayer = CAShapeLayer()
    private let caretLayer = CALayer()
    private var drawnSize = CGSize.zero

    private static let wallpaperTop = UIColor(red: 0x1B / 255, green: 0x1D / 255, blue: 0x3A / 255, alpha: 1)
    private static let wallpaperBottom = UIColor(red: 0x1F / 255, green: 0x3B / 255, blue: 0x45 / 255, alpha: 1)
    private static let windowBody = UIColor(red: 0x1E / 255, green: 0x1E / 255, blue: 0x1E / 255, alpha: 1)
    private static let titleBar = UIColor(red: 0x2A / 255, green: 0x2A / 255, blue: 0x2C / 255, alpha: 1)
    private static let dots = [UIColor(red: 0xFF / 255, green: 0x5F / 255, blue: 0x57 / 255, alpha: 1),
                               UIColor(red: 0xFE / 255, green: 0xBC / 255, blue: 0x2E / 255, alpha: 1),
                               UIColor(red: 0x28 / 255, green: 0xC8 / 255, blue: 0x40 / 255, alpha: 1)]

    /// The classic arrow, tip at the origin, 19 points tall at 1x.
    private static let arrow: [CGPoint] = [CGPoint(x: 0, y: 0), CGPoint(x: 0, y: 16.6), CGPoint(x: 4, y: 12.9),
                                           CGPoint(x: 6.6, y: 19), CGPoint(x: 9.3, y: 17.9), CGPoint(x: 6.8, y: 11.9),
                                           CGPoint(x: 12, y: 11.9)]

    init(mac: DemoMac) {
        self.mac = mac
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        isOpaque = true
        backgroundColor = .black
        contentMode = .redraw
        isAccessibilityElement = true
        accessibilityIdentifier = "demo-mac"
        accessibilityLabel = "Demo Mac"
        accessibilityValue = mac.text

        caretLayer.backgroundColor = UIColor(white: 1, alpha: 0.92).cgColor
        layer.addSublayer(caretLayer)
        pointerLayer.fillColor = UIColor.black.cgColor
        pointerLayer.strokeColor = UIColor.white.cgColor
        pointerLayer.lineJoin = .round
        pointerLayer.shadowColor = UIColor.black.cgColor
        pointerLayer.shadowOpacity = 0.35
        pointerLayer.shadowOffset = CGSize(width: 0, height: 1)
        layer.addSublayer(pointerLayer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// View points per pretend-Mac point.
    private var unit: CGFloat { bounds.width / DemoLayout.size.width }
    /// The pointer is drawn a little larger than a Mac's own at this size, and never smaller than readable.
    private var pointerScale: CGFloat { max(unit * 1.8, 0.8) }

    override var contentScaleFactor: CGFloat {
        didSet {
            for sub in [pointerLayer, caretLayer] { sub.contentsScale = contentScaleFactor }
            setNeedsDisplay()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.size != drawnSize else { return }
        drawnSize = bounds.size
        let k = pointerScale
        let path = UIBezierPath()
        for (i, p) in Self.arrow.enumerated() {
            let q = CGPoint(x: p.x * k, y: p.y * k)
            if i == 0 { path.move(to: q) } else { path.addLine(to: q) }
        }
        path.close()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pointerLayer.path = path.cgPath
        pointerLayer.lineWidth = 1.3 * k
        pointerLayer.shadowRadius = 1.2 * k
        placePointer()
        placeCaret()
        CATransaction.commit()
        setNeedsDisplay()
    }

    func macChanged(_ changes: DemoChange) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if changes.pointer { placePointer() }
        if changes.text || changes.scroll {
            placeCaret()
            setNeedsDisplay()
        }
        CATransaction.commit()
        if changes.text {
            accessibilityValue = mac.text
            restartBlink()
        }
        if changes.click { ring() }
    }

    private func placePointer() {
        pointerLayer.frame = CGRect(x: mac.pointer.x * unit, y: mac.pointer.y * unit, width: 1, height: 1)
    }

    private func placeCaret() {
        let area = DemoLayout.shared.textArea
        let c = mac.caret
        let top = area.minY + c.minY - mac.scroll
        caretLayer.isHidden = top < area.minY - 1 || top + c.height > area.maxY + 1
        caretLayer.frame = CGRect(x: (area.minX + c.minX) * unit, y: top * unit,
                                  width: max(c.width * unit, 1), height: c.height * unit)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { restartBlink() }
    }

    /// Solid while typing, then on and off every half second.
    private func restartBlink() {
        caretLayer.removeAnimation(forKey: "blink")
        let blink = CAKeyframeAnimation(keyPath: "opacity")
        blink.values = [1, 0]
        blink.keyTimes = [0, 0.5, 1]
        blink.calculationMode = .discrete
        blink.duration = 1.06
        blink.repeatCount = .infinity
        blink.beginTime = CACurrentMediaTime() + 0.5
        blink.fillMode = .backwards
        caretLayer.add(blink, forKey: "blink")
    }

    /// A short expanding ring where the pointer clicked.
    private func ring() {
        let radius = max(26 * unit, 12)
        let ring = CAShapeLayer()
        ring.contentsScale = contentScaleFactor
        ring.frame = CGRect(x: mac.pointer.x * unit - radius, y: mac.pointer.y * unit - radius, width: 2 * radius, height: 2 * radius)
        ring.path = UIBezierPath(ovalIn: ring.bounds).cgPath
        ring.fillColor = UIColor.clear.cgColor
        ring.strokeColor = UIColor(white: 1, alpha: 0.85).cgColor
        ring.lineWidth = max(2.5 * unit, 1.5)
        ring.opacity = 0
        layer.insertSublayer(ring, below: pointerLayer)
        let grow = CABasicAnimation(keyPath: "transform.scale")
        grow.fromValue = 0.35
        grow.toValue = 1
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.9
        fade.toValue = 0
        let group = CAAnimationGroup()
        group.animations = [grow, fade]
        group.duration = 0.35
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        CATransaction.begin()
        CATransaction.setCompletionBlock { ring.removeFromSuperlayer() }
        ring.add(group, forKey: "ring")
        CATransaction.commit()
    }

    // MARK: Drawing

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext(), bounds.width > 0 else { return }
        ctx.scaleBy(x: unit, y: unit)
        let size = DemoLayout.size
        let layout = DemoLayout.shared

        // Wallpaper: a soft diagonal gradient.
        let colors = [Self.wallpaperTop.cgColor, Self.wallpaperBottom.cgColor] as CFArray
        if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
            ctx.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: size.width, y: size.height), options: [])
        }

        // Menu bar.
        UIColor(white: 1, alpha: 0.09).setFill()
        UIRectFillUsingBlendMode(CGRect(x: 0, y: 0, width: size.width, height: DemoLayout.menuBarHeight), .normal)
        let menuColor = UIColor(white: 1, alpha: 0.92)
        var x: CGFloat = 22
        for (index, word) in ["Demo Mac", "File", "Edit", "View"].enumerated() {
            let font = index == 0 ? DemoLayout.menuBoldFont : DemoLayout.menuFont
            x += draw(word, font: font, color: menuColor, left: x, centerY: DemoLayout.menuBarHeight / 2) + 26
        }
        let clock = "9:41" as NSString
        let clockWidth = clock.size(withAttributes: [.font: DemoLayout.menuFont]).width
        draw("9:41", font: DemoLayout.menuFont, color: menuColor, left: size.width - 22 - clockWidth, centerY: DemoLayout.menuBarHeight / 2)

        // The window.
        let window = DemoLayout.window
        let shape = UIBezierPath(roundedRect: window, cornerRadius: DemoLayout.windowCorner)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 16), blur: 48, color: UIColor(white: 0, alpha: 0.5).cgColor)
        Self.windowBody.setFill()
        shape.fill()
        ctx.restoreGState()
        ctx.saveGState()
        shape.addClip()
        Self.titleBar.setFill()
        UIRectFill(CGRect(x: window.minX, y: window.minY, width: window.width, height: DemoLayout.titleBarHeight))
        UIColor(white: 0, alpha: 0.5).setFill()
        UIRectFill(CGRect(x: window.minX, y: window.minY + DemoLayout.titleBarHeight - 1, width: window.width, height: 1))
        ctx.restoreGState()
        UIColor(white: 1, alpha: 0.12).setStroke()
        shape.lineWidth = 1
        shape.stroke()
        for (i, color) in Self.dots.enumerated() {
            color.setFill()
            let c = CGPoint(x: window.minX + 22 + CGFloat(i) * 22, y: window.minY + DemoLayout.titleBarHeight / 2)
            UIBezierPath(ovalIn: CGRect(x: c.x - 6.5, y: c.y - 6.5, width: 13, height: 13)).fill()
        }
        let title = "Notes" as NSString
        let titleWidth = title.size(withAttributes: [.font: DemoLayout.titleFont]).width
        draw("Notes", font: DemoLayout.titleFont, color: UIColor(white: 1, alpha: 0.8),
             left: window.midX - titleWidth / 2, centerY: window.minY + DemoLayout.titleBarHeight / 2)

        // Body: the welcome, two notes, then what was typed.
        (DemoLayout.heading as NSString).draw(in: layout.headingRect, withAttributes: [.font: DemoLayout.headingFont,
                                                                                       .foregroundColor: UIColor.white])
        for (note, rect) in zip(DemoLayout.notes, layout.noteRects) {
            (note as NSString).draw(with: rect, options: [.usesLineFragmentOrigin, .usesFontLeading],
                                    attributes: [.font: DemoLayout.noteFont, .foregroundColor: UIColor(white: 1, alpha: 0.55)],
                                    context: nil)
        }
        ctx.saveGState()
        ctx.clip(to: layout.textArea)
        mac.drawText(at: CGPoint(x: layout.textArea.minX, y: layout.textArea.minY - mac.scroll))
        ctx.restoreGState()
    }

    /// One line of text, vertically centred; returns its width.
    @discardableResult
    private func draw(_ text: String, font: UIFont, color: UIColor, left: CGFloat, centerY: CGFloat) -> CGFloat {
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let size = (text as NSString).size(withAttributes: attributes)
        (text as NSString).draw(at: CGPoint(x: left, y: centerY - size.height / 2), withAttributes: attributes)
        return size.width
    }
}

/// The small "Demo" pill over the corner of the pretend Mac.
final class DemoPill: UILabel {
    private let inset = UIEdgeInsets(top: 3, left: 9, bottom: 3, right: 9)

    override init(frame: CGRect) {
        super.init(frame: frame)
        text = "Demo"
        font = .preferredFont(forTextStyle: .caption1)
        adjustsFontForContentSizeCategory = false
        textColor = .white
        textAlignment = .center
        backgroundColor = UIColor(white: 0, alpha: 0.4)
        layer.cornerCurve = .continuous
        layer.masksToBounds = true
        accessibilityIdentifier = "demo-pill"
        accessibilityLabel = "Demo"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func drawText(in rect: CGRect) {
        super.drawText(in: rect.inset(by: inset))
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let inner = super.sizeThatFits(size)
        return CGSize(width: ceil(inner.width) + inset.left + inset.right, height: ceil(inner.height) + inset.top + inset.bottom)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = bounds.height / 2
    }
}
