import UIKit
import AVFoundation

/// The Mac's screen. Touch it directly to click, pinch to zoom; when zoomed the
/// view follows the Mac's cursor.
final class ScreenView: UIView, UIGestureRecognizerDelegate {
    var send: (([InputEvent]) -> Void)?
    var onClick: (() -> Void)?
    /// Half open, the picture sits on the fold and the spare black goes up top, where a bezel would be.
    var alignsToBottom = false {
        didSet { if alignsToBottom != oldValue { setNeedsLayout() } }
    }

    var streamSize = CGSize(width: 16, height: 10) {
        didSet { if streamSize != oldValue { setNeedsLayout() } }
    }
    private(set) var zoom: CGFloat = 1

    private let content = UIView()
    private let videoLayer: AVSampleBufferDisplayLayer?
    /// A picture the app draws itself (the demo's pretend Mac), in place of the video.
    private let pictureView: UIView?
    private var viewCenter = CGPoint(x: 0.5, y: 0.5) // middle of what is visible, 0...1
    private var cursor = CGPoint(x: 0.5, y: 0.5)
    private var pinchStartZoom: CGFloat = 1
    private var lastScrollTranslation = CGPoint.zero

    /// Pinned near the picture's top-left corner, outside the zoom (the demo's "Demo" pill).
    var badge: UIView? {
        didSet {
            oldValue?.removeFromSuperview()
            if let badge { addSubview(badge) }
            setNeedsLayout()
        }
    }

    init(videoLayer: AVSampleBufferDisplayLayer) {
        self.videoLayer = videoLayer
        pictureView = nil
        super.init(frame: .zero)
        content.layer.addSublayer(videoLayer)
        setUp()
        #if DEBUG
        // Layout renders (`-layoutSnapshot`) cannot draw the video layer, so show where the fitted picture sits.
        if UserDefaults.standard.string(forKey: "layoutSnapshot") != nil {
            content.backgroundColor = UIColor(red: 0.22, green: 0.36, blue: 0.55, alpha: 1)
            content.layer.borderColor = UIColor.white.cgColor
            content.layer.borderWidth = 2
        }
        #endif
    }

    init(pictureView: UIView) {
        videoLayer = nil
        self.pictureView = pictureView
        super.init(frame: .zero)
        pictureView.isUserInteractionEnabled = false // touches are the gestures' below
        content.addSubview(pictureView)
        setUp()
    }

    private func setUp() {
        backgroundColor = .black
        clipsToBounds = true
        content.backgroundColor = .black
        addSubview(content)

        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
        let hold = UILongPressGestureRecognizer(target: self, action: #selector(held(_:)))
        hold.minimumPressDuration = 0.45
        let drag = UIPanGestureRecognizer(target: self, action: #selector(dragged(_:)))
        drag.maximumNumberOfTouches = 1
        let scroll = UIPanGestureRecognizer(target: self, action: #selector(scrolled(_:)))
        scroll.minimumNumberOfTouches = 2
        scroll.maximumNumberOfTouches = 2
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinched(_:)))
        scroll.delegate = self
        pinch.delegate = self
        [tap, hold, drag, scroll, pinch].forEach(addGestureRecognizer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        (g is UIPinchGestureRecognizer && other is UIPanGestureRecognizer) || (g is UIPanGestureRecognizer && other is UIPinchGestureRecognizer)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0, bounds.height > 0, streamSize.width > 0, streamSize.height > 0 else { return }
        let fitted = AVMakeRect(aspectRatio: streamSize, insideRect: bounds)
        content.transform = .identity
        content.bounds = CGRect(origin: .zero, size: fitted.size)
        content.center = CGPoint(x: bounds.midX, y: alignsToBottom ? bounds.maxY - fitted.height / 2 : bounds.midY)
        if let videoLayer {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            videoLayer.frame = content.bounds
            CATransaction.commit()
        }
        if let pictureView {
            pictureView.frame = content.bounds
            updatePictureScale()
        }
        if let badge {
            // Clear of the demo's menu bar (3 percent of the height) and of a rounded screen corner.
            let size = badge.sizeThatFits(bounds.size)
            badge.frame = CGRect(x: content.center.x - fitted.width / 2 + 16,
                                 y: content.center.y - fitted.height / 2 + max(fitted.height * 0.03 + 8, 20),
                                 width: size.width, height: size.height)
        }
        applyZoom()
    }

    /// A drawn picture is drawn again at the zoom it settles on, so it stays sharp (within a sensible size).
    private func updatePictureScale() {
        guard let pictureView, pictureView.bounds.width > 0 else { return }
        let screen = traitCollection.displayScale > 0 ? traitCollection.displayScale : 2
        let scale = max(screen, min(screen * zoom, 2880 / pictureView.bounds.width))
        if abs(pictureView.contentScaleFactor - scale) > 0.01 { pictureView.contentScaleFactor = scale }
    }

    func cursorMoved(to point: CGPoint) {
        cursor = point
        guard zoom > 1.01 else { return }
        let half = visibleHalfExtent()
        let marginX = half.x * 0.3, marginY = half.y * 0.3
        var c = viewCenter
        if point.x < c.x - half.x + marginX { c.x = point.x + half.x - marginX }
        if point.x > c.x + half.x - marginX { c.x = point.x - half.x + marginX }
        if point.y < c.y - half.y + marginY { c.y = point.y + half.y - marginY }
        if point.y > c.y + half.y - marginY { c.y = point.y - half.y + marginY }
        if c != viewCenter {
            viewCenter = c
            applyZoom()
        }
    }

    /// Half of the visible width and height, as a fraction of the Mac screen.
    private func visibleHalfExtent() -> CGPoint {
        let size = content.bounds.size
        guard size.width > 0, size.height > 0 else { return CGPoint(x: 0.5, y: 0.5) }
        return CGPoint(x: min(0.5, bounds.width / (zoom * size.width) / 2),
                       y: min(0.5, bounds.height / (zoom * size.height) / 2))
    }

    private func applyZoom() {
        let size = content.bounds.size
        let half = visibleHalfExtent()
        viewCenter.x = half.x >= 0.5 ? 0.5 : min(max(viewCenter.x, half.x), 1 - half.x)
        viewCenter.y = half.y >= 0.5 ? 0.5 : min(max(viewCenter.y, half.y), 1 - half.y)
        let tx = -zoom * (viewCenter.x - 0.5) * size.width
        let ty = -zoom * (viewCenter.y - 0.5) * size.height
        content.transform = CGAffineTransform(translationX: tx, y: ty).scaledBy(x: zoom, y: zoom)
    }

    private func normalized(_ g: UIGestureRecognizer) -> CGPoint? {
        let size = content.bounds.size
        guard size.width > 0, size.height > 0 else { return nil }
        let p = g.location(in: content)
        return CGPoint(x: min(max(p.x / size.width, 0), 1), y: min(max(p.y / size.height, 0), 1))
    }

    @objc private func tapped(_ g: UITapGestureRecognizer) {
        guard let p = normalized(g) else { return }
        send?([.moveAbs(x: Float(p.x), y: Float(p.y)),
               .button(index: 0, down: true, clicks: 0), .button(index: 0, down: false, clicks: 0)])
        onClick?()
    }

    @objc private func held(_ g: UILongPressGestureRecognizer) {
        guard g.state == .began, let p = normalized(g) else { return }
        Haptics.shared.play(.click)
        send?([.moveAbs(x: Float(p.x), y: Float(p.y)),
               .button(index: 1, down: true, clicks: 1), .button(index: 1, down: false, clicks: 1)])
        onClick?()
    }

    @objc private func dragged(_ g: UIPanGestureRecognizer) {
        guard let p = normalized(g) else { return }
        switch g.state {
        case .began:
            send?([.moveAbs(x: Float(p.x), y: Float(p.y)), .button(index: 0, down: true, clicks: 1)])
        case .changed:
            send?([.moveAbs(x: Float(p.x), y: Float(p.y))])
        case .ended, .cancelled, .failed:
            send?([.button(index: 0, down: false, clicks: 1)])
            onClick?()
        default:
            break
        }
    }

    @objc private func scrolled(_ g: UIPanGestureRecognizer) {
        let t = g.translation(in: self)
        if g.state == .began { lastScrollTranslation = .zero }
        let dx = t.x - lastScrollTranslation.x, dy = t.y - lastScrollTranslation.y
        lastScrollTranslation = t
        if g.state == .changed { send?([.scroll(dx: Float(dx * 1.7), dy: Float(dy * 1.7))]) }
    }

    @objc private func pinched(_ g: UIPinchGestureRecognizer) {
        switch g.state {
        case .began:
            pinchStartZoom = zoom
            if let p = normalized(g) { viewCenter = p }
        case .changed:
            zoom = min(max(pinchStartZoom * g.scale, 1), 4)
            applyZoom()
        default:
            if zoom < 1.08 { zoom = 1; applyZoom() }
            updatePictureScale()
        }
    }
}
