import UIKit

/// The Mac's real display sizes, the same choices as System Settings, from Larger Text to More Space.
/// A tap resizes the Mac itself and the picture keeps running while it does.
final class DisplayPanel: UIView {
    var onPick: ((Int) -> Void)?
    var cardCenterY: CGFloat = 0 { didSet { setNeedsLayout() } }
    var isAvailable: Bool { !widths.isEmpty }

    private let card = UIView()
    private let title = UILabel()
    private let detail = UILabel()
    private let reset = UIButton(type: .system)
    private let row = UIStackView()
    private let larger = UILabel()
    private let more = UILabel()
    private var stops: [DisplayStop] = []
    private var widths: [Int] = []
    private var base = 0
    private var now = 0
    private var aspect = 1.547

    private static let padding: CGFloat = 16
    private static let cardHeight: CGFloat = 164

    override init(frame: CGRect) {
        super.init(frame: frame)
        isHidden = true
        alpha = 0

        card.backgroundColor = UIColor(red: 0.125, green: 0.125, blue: 0.135, alpha: 1)
        card.layer.cornerRadius = 18
        card.layer.cornerCurve = .continuous
        card.layer.borderWidth = 1
        card.layer.borderColor = UIColor(white: 1, alpha: 0.1).cgColor
        card.layer.shadowColor = UIColor.black.cgColor
        card.layer.shadowOpacity = 0.5
        card.layer.shadowRadius = 18
        card.layer.shadowOffset = CGSize(width: 0, height: 6)
        addSubview(card)

        title.text = "Display"
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        title.textColor = .white
        detail.font = .systemFont(ofSize: 12)
        detail.textColor = UIColor(white: 1, alpha: 0.55)

        reset.setTitle("Use Mac's setting", for: .normal)
        reset.titleLabel?.font = .systemFont(ofSize: 13, weight: .medium)
        reset.tintColor = UIColor(white: 1, alpha: 0.8)
        reset.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.pick(self.base)
        }, for: .touchUpInside)

        row.axis = .horizontal
        row.distribution = .fillEqually
        row.spacing = 8

        for (label, text, alignment) in [(larger, "Larger Text", NSTextAlignment.left), (more, "More Space", .right)] {
            label.text = text
            label.textAlignment = alignment
            label.font = .systemFont(ofSize: 12)
            label.textColor = UIColor(white: 1, alpha: 0.55)
        }
        [title, detail, reset, row, larger, more].forEach(card.addSubview)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(_ ack: HelloAck) {
        let fresh = Array((ack.displayWidths ?? []).filter { (1...20_000).contains($0) }.prefix(12))
        base = ack.displayBaseWidth ?? 0
        now = ack.displayNowWidth ?? 0
        // From the host: a zero, negative or absurd size keeps the last good shape rather than dividing by it.
        let shape = ack.displayPointWidth / max(ack.displayPointHeight, 1)
        if shape.isFinite, (0.25...8).contains(shape) { aspect = shape }
        if fresh != widths {
            widths = fresh
            rebuild()
        }
        refresh()
    }

    func setOpen(_ open: Bool) {
        if open { isHidden = false }
        UIView.animate(withDuration: 0.16, animations: { self.alpha = open ? 1 : 0 }, completion: { _ in
            if self.alpha == 0 { self.isHidden = true }
        })
    }

    private func rebuild() {
        stops.forEach { $0.removeFromSuperview() }
        let last = max(widths.count - 1, 1)
        stops = widths.enumerated().map { index, width in
            // Narrowest first, so Larger Text is on the left as it is on the Mac.
            let stop = DisplayStop(points: width, textSize: 22 - CGFloat(index) / CGFloat(last) * 11)
            stop.addAction(UIAction { [weak self] _ in self?.pick(width) }, for: .touchUpInside)
            row.addArrangedSubview(stop)
            return stop
        }
    }

    private func refresh() {
        stops.forEach { $0.isSelected = $0.points == now }
        let height = (Double(now) / aspect).rounded()
        detail.text = height.isFinite && abs(height) < 1_000_000 ? "Looks like \(now) x \(Int(height))" : nil
        reset.isHidden = now == base
    }

    private func pick(_ width: Int) {
        guard width != now else { return }
        now = width
        refresh()
        Haptics.shared.play(.click)
        onPick?(width == base ? 0 : width)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let width = min(bounds.width - 24, 460)
        let p = Self.padding
        let top = min(max(cardCenterY - Self.cardHeight / 2, 8), bounds.height - Self.cardHeight - 8)
        card.frame = CGRect(x: (bounds.width - width) / 2, y: top, width: width, height: Self.cardHeight)
        title.frame = CGRect(x: p, y: 14, width: 120, height: 20)
        detail.frame = CGRect(x: p, y: 36, width: width - 2 * p, height: 16)
        let resetSize = reset.sizeThatFits(CGSize(width: 180, height: 30))
        reset.frame = CGRect(x: width - p - resetSize.width, y: 10, width: resetSize.width, height: 30)
        row.frame = CGRect(x: p, y: 62, width: width - 2 * p, height: 66)
        larger.frame = CGRect(x: p, y: 136, width: 120, height: 16)
        more.frame = CGRect(x: width - p - 120, y: 136, width: 120, height: 16)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let point = touches.first?.location(in: self), !card.frame.contains(point) else { return }
        setOpen(false)
    }
}

private final class DisplayStop: UIControl {
    let points: Int
    private let sample = UILabel()
    private let number = UILabel()

    init(points: Int, textSize: CGFloat) {
        self.points = points
        super.init(frame: .zero)
        layer.cornerRadius = 10
        layer.cornerCurve = .continuous
        layer.borderWidth = 1
        sample.text = "Aa"
        sample.font = .systemFont(ofSize: textSize, weight: .medium)
        sample.textAlignment = .center
        number.text = String(points)
        number.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        number.textAlignment = .center
        addSubview(sample)
        addSubview(number)
        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityLabel = "\(points) points wide"
        accessibilityIdentifier = "display-\(points)"
        restyle()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isSelected: Bool { didSet { restyle() } }
    override var isHighlighted: Bool { didSet { alpha = isHighlighted ? 0.6 : 1 } }

    private func restyle() {
        backgroundColor = isSelected ? .white : UIColor(white: 1, alpha: 0.07)
        layer.borderColor = UIColor(white: 1, alpha: isSelected ? 0 : 0.1).cgColor
        sample.textColor = isSelected ? .black : UIColor(white: 1, alpha: 0.9)
        number.textColor = isSelected ? UIColor(white: 0, alpha: 0.6) : UIColor(white: 1, alpha: 0.45)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        sample.frame = CGRect(x: 0, y: 8, width: bounds.width, height: bounds.height - 30)
        number.frame = CGRect(x: 0, y: bounds.height - 20, width: bounds.width, height: 14)
    }
}
