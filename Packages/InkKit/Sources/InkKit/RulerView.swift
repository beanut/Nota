import UIKit

/// Shows the `Ruler` over the canvas and moves it: one finger drags it, two fingers turn it (snapping to
/// every 15°), and the angle it's at is printed on it. It covers its host (the page's canvas, or the
/// continuous-scrolling view), but only the ruler's body takes touches: everywhere else touches go straight
/// through to the canvas.
///
/// The Pencil writes on the ruler as on paper: a Pencil touch on its body is handed to the canvas under it
/// (`pencilTarget`), and the canvas snaps the stroke to the nearer edge (`CanvasView+Ruler`). Fingers on the
/// body move the ruler and never draw.
///
/// Moving and turning the ruler only moves its layer; its ticks are drawn again only when the zoom or its
/// mode changes. The ticks are page centimetres and millimetres at the current zoom.
final class RulerView: UIView, UIGestureRecognizerDelegate {
    private(set) var ruler: Ruler
    /// The editor whose ruler this is: it keeps the ruler's place for the next page and layout.
    private weak var controller: CanvasController?
    /// The canvas a Pencil touch at a point (in this view) writes on.
    var pencilTarget: ((CGPoint) -> UIView?)?
    private var theme: InkTheme
    private let body = RulerBodyView()
    private let angleLabel = UILabel()
    private let readout = RulerReadoutLabel()
    /// Pencil touches handed on, and where they went.
    private var forwarded: [UITouch: UIView] = [:]
    /// Not yet placed: the ruler goes in the middle of the view once it has a size.
    private var needsCentering: Bool
    /// The unsnapped angle while two fingers turn the ruler.
    private var turning: CGFloat?

    init(controller: CanvasController) {
        self.controller = controller
        needsCentering = controller.ruler == nil
        ruler = controller.ruler ?? Ruler(center: .zero, angle: 0)
        theme = controller.theme
        super.init(frame: .zero)
        backgroundColor = .clear
        isMultipleTouchEnabled = true
        isAccessibilityElement = true
        accessibilityLabel = String(localized: "Ruler")
        accessibilityHint = String(localized: "Drag with one finger to move it, or turn it with two.")
        addSubview(body)
        body.addSubview(angleLabel)
        angleLabel.textAlignment = .center
        angleLabel.font = UIFont.monospacedDigitSystemFont(ofSize: UIFont.preferredFont(forTextStyle: .footnote).pointSize,
                                                           weight: .semibold)
        readout.isHidden = true
        addSubview(readout)
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.maximumNumberOfTouches = 2
        let rotate = UIRotationGestureRecognizer(target: self, action: #selector(handleRotation(_:)))
        for g in [pan, rotate] as [UIGestureRecognizer] {
            g.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
            g.delegate = self
            addGestureRecognizer(g)
        }
        apply(theme)
        place()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Adds the ruler to `host` (or updates or removes it) to match `controller`: shown while
    /// `rulerVisible` is on. Returns the ruler view, if it's shown.
    @discardableResult
    static func sync(in host: UIView, controller: CanvasController,
                     pencilTarget: @escaping (CGPoint) -> UIView?) -> RulerView? {
        let existing = host.subviews.lazy.compactMap { $0 as? RulerView }.first
        guard controller.rulerVisible else {
            existing?.removeFromSuperview()
            return nil
        }
        let view = existing ?? RulerView(controller: controller)
        if existing == nil {
            view.frame = host.bounds
            view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            host.addSubview(view)
        }
        view.pencilTarget = pencilTarget
        view.apply(controller.theme)
        view.setMode(controller.rulerMode)
        controller.rulerView = view
        return view
    }

    func apply(_ theme: InkTheme) {
        self.theme = theme
        body.theme = theme
        angleLabel.textColor = theme.textPrimary
        readout.apply(theme)
    }

    func setMode(_ mode: Ruler.Mode) {
        guard ruler.mode != mode else { return }
        ruler.mode = mode
        body.mode = mode
        place()
        controller?.ruler = ruler
    }

    /// The zoom changed: the ticks are page centimetres, so they're drawn again.
    func pageScaleDidChange() {
        body.pageScale = controller?.canvas?.viewTransform.scale ?? 1
    }

    // MARK: Layout

    override func layoutSubviews() {
        super.layoutSubviews()
        if needsCentering, bounds.width > 0, bounds.height > 0 {
            needsCentering = false
            ruler.center = CGPoint(x: bounds.midX, y: bounds.midY)
            controller?.ruler = ruler
            place()
        }
    }

    /// Puts the body where the ruler is, turned to its angle. A transform, so nothing is redrawn.
    private func place() {
        body.mode = ruler.mode
        body.pageScale = controller?.canvas?.viewTransform.scale ?? 1
        let size = body.intrinsicContentSize
        body.bounds = CGRect(origin: .zero, size: size)
        body.center = ruler.center
        body.transform = CGAffineTransform(rotationAngle: ruler.angle)
        let labelCenter = ruler.mode == .ruler ? CGPoint(x: size.width / 2, y: size.height / 2)
            : CGPoint(x: size.width / 2, y: size.height / 2 - Ruler.protractorRadius * 0.35)
        angleLabel.text = "\(ruler.displayedDegrees)°"
        angleLabel.sizeToFit()
        angleLabel.center = labelCenter
    }

    // MARK: Readout

    /// Shows `text` (a length or angle) by `point` (this view's space), where the stroke along the ruler is.
    func showReadout(_ text: String, near point: CGPoint) {
        if readout.text != text {
            readout.text = text
            readout.sizeToFit()
        }
        readout.isHidden = false
        // Above the Pencil's tip, away from the hand, and kept on screen.
        let size = readout.bounds.size
        let x = min(max(point.x, size.width / 2 + 8), bounds.width - size.width / 2 - 8)
        let y = max(point.y - 44, size.height / 2 + 8)
        readout.center = CGPoint(x: x, y: y)
    }

    func hideReadout() {
        readout.isHidden = true
    }

    // MARK: Touches

    /// Only the ruler's body takes touches.
    override func point(inside point: CGPoint, with _: UIEvent?) -> Bool {
        ruler.contains(point)
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        // Fingers are the gesture recognizers'; the Pencil writes on the canvas under it.
        for touch in touches where touch.type == .pencil {
            if let target = pencilTarget?(touch.location(in: self)) {
                forwarded[touch] = target
                target.touchesBegan([touch], with: event)
            }
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            forwarded[touch]?.touchesMoved([touch], with: event)
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            forwarded.removeValue(forKey: touch)?.touchesEnded([touch], with: event)
        }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            forwarded.removeValue(forKey: touch)?.touchesCancelled([touch], with: event)
        }
    }

    override func touchesEstimatedPropertiesUpdated(_ touches: Set<UITouch>) {
        for touch in touches {
            forwarded[touch]?.touchesEstimatedPropertiesUpdated([touch])
        }
    }

    @objc private func handlePan(_ g: UIPanGestureRecognizer) {
        guard g.state == .began || g.state == .changed else { return }
        let t = g.translation(in: self)
        g.setTranslation(.zero, in: self)
        ruler.center = CGPoint(x: ruler.center.x + t.x, y: ruler.center.y + t.y)
        place()
        controller?.ruler = ruler
    }

    @objc private func handleRotation(_ g: UIRotationGestureRecognizer) {
        switch g.state {
        case .began, .changed:
            let raw = (turning ?? ruler.angle) + g.rotation
            g.rotation = 0
            turning = raw
            ruler.angle = Ruler.snappedAngle(raw)
            place()
            controller?.ruler = ruler
        default:
            turning = nil
        }
    }

    func gestureRecognizer(_: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith _: UIGestureRecognizer) -> Bool {
        true
    }
}

/// The ruler's body: a translucent raised strip with page-centimetre ticks along both edges, or a half disc
/// with degree ticks round its arc. Drawn in its own unrotated space; `RulerView` turns it.
private final class RulerBodyView: UIView {
    var theme = InkTheme.standard {
        didSet { setNeedsDisplay() }
    }

    var mode = Ruler.Mode.ruler {
        didSet {
            if mode != oldValue {
                setNeedsDisplay()
            }
        }
    }

    /// View points per page point, so the ticks are the page's centimetres.
    var pageScale: CGFloat = 1 {
        didSet {
            if abs(pageScale - oldValue) > 1e-4 {
                setNeedsDisplay()
            }
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        isUserInteractionEnabled = false
        contentMode = .redraw
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: CGSize {
        switch mode {
        case .ruler: CGSize(width: Ruler.length, height: Ruler.width)
        case .protractor: CGSize(width: 2 * Ruler.protractorRadius, height: 2 * Ruler.protractorRadius)
        }
    }

    override func draw(_: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        let traits = traitCollection
        let fill = theme.surfaceRaised.resolvedColor(with: traits).withAlphaComponent(0.86).cgColor
        let edge = theme.border.resolvedColor(with: traits).cgColor
        let tick = theme.textSecondary.resolvedColor(with: traits).cgColor
        ctx.setLineCap(.round)
        switch mode {
        case .ruler: drawRuler(in: ctx, fill: fill, edge: edge, tick: tick)
        case .protractor: drawProtractor(in: ctx, fill: fill, edge: edge, tick: tick)
        }
    }

    private func drawRuler(in ctx: CGContext, fill: CGColor, edge: CGColor, tick: CGColor) {
        let r = bounds
        let outline = UIBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), cornerRadius: InkMetrics.controlRadius).cgPath
        ctx.addPath(outline)
        ctx.setFillColor(fill)
        ctx.fillPath()
        ctx.addPath(outline)
        ctx.setStrokeColor(edge)
        ctx.setLineWidth(1)
        ctx.strokePath()
        // Millimetres from the middle out, both ways, along both edges; skipped when they'd be a blur.
        let mm = RulerMeasurement.pointsPerCentimetre / 10 * pageScale
        guard mm > 0.5 else { return }
        let showsMillimetres = mm >= 3
        let unit = showsMillimetres ? mm : mm * 10
        let count = Int((r.width / 2) / unit)
        let path = CGMutablePath()
        var labels: [(String, CGFloat)] = []
        for i in -count ... count {
            let x = r.midX + CGFloat(i) * unit
            let isCentimetre = !showsMillimetres || i % 10 == 0
            let isHalf = showsMillimetres && i % 5 == 0
            let length: CGFloat = isCentimetre ? 14 : isHalf ? 10 : 6
            path.move(to: CGPoint(x: x, y: r.minY))
            path.addLine(to: CGPoint(x: x, y: r.minY + length))
            path.move(to: CGPoint(x: x, y: r.maxY))
            path.addLine(to: CGPoint(x: x, y: r.maxY - length))
            let cm = showsMillimetres ? i / 10 : i
            let every = unit * (showsMillimetres ? 10 : 1) >= 24 ? 1 : 5
            if isCentimetre, cm != 0, abs(cm) % every == 0 {
                labels.append(("\(abs(cm))", x))
            }
        }
        ctx.addPath(path)
        ctx.setStrokeColor(tick)
        ctx.setLineWidth(1)
        ctx.strokePath()
        let font = UIFont.monospacedDigitSystemFont(ofSize: UIFont.preferredFont(forTextStyle: .caption2).pointSize,
                                                    weight: .regular)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: UIColor(cgColor: tick)]
        for (text, x) in labels {
            let size = (text as NSString).size(withAttributes: attributes)
            (text as NSString).draw(at: CGPoint(x: x - size.width / 2, y: r.minY + 16), withAttributes: attributes)
        }
    }

    private func drawProtractor(in ctx: CGContext, fill: CGColor, edge: CGColor, tick: CGColor) {
        let radius = Ruler.protractorRadius
        let c = CGPoint(x: bounds.midX, y: bounds.midY)
        let disc = CGMutablePath()
        disc.addArc(center: c, radius: radius, startAngle: .pi, endAngle: 2 * .pi, clockwise: false)
        disc.closeSubpath()
        ctx.addPath(disc)
        ctx.setFillColor(fill)
        ctx.fillPath()
        ctx.addPath(disc)
        ctx.setStrokeColor(edge)
        ctx.setLineWidth(1)
        ctx.strokePath()
        let path = CGMutablePath()
        let font = UIFont.monospacedDigitSystemFont(ofSize: UIFont.preferredFont(forTextStyle: .caption2).pointSize,
                                                    weight: .regular)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: UIColor(cgColor: tick)]
        for degree in 0 ... 180 {
            let a = CGFloat.pi + CGFloat(degree) * .pi / 180
            let length: CGFloat = degree % 10 == 0 ? 14 : degree % 5 == 0 ? 10 : 5
            let outer = CGPoint(x: c.x + cos(a) * radius, y: c.y + sin(a) * radius)
            let inner = CGPoint(x: c.x + cos(a) * (radius - length), y: c.y + sin(a) * (radius - length))
            path.move(to: outer)
            path.addLine(to: inner)
            if degree % 30 == 0 {
                let text = "\(degree)" as NSString
                let size = text.size(withAttributes: attributes)
                let at = CGPoint(x: c.x + cos(a) * (radius - 26), y: c.y + sin(a) * (radius - 26))
                text.draw(at: CGPoint(x: at.x - size.width / 2, y: at.y - size.height / 2), withAttributes: attributes)
            }
        }
        // The centre mark on the baseline.
        path.move(to: CGPoint(x: c.x, y: c.y))
        path.addLine(to: CGPoint(x: c.x, y: c.y - 10))
        ctx.addPath(path)
        ctx.setStrokeColor(tick)
        ctx.setLineWidth(1)
        ctx.strokePath()
    }
}

/// The length or angle by the Pencil while it draws along the ruler: a small raised capsule.
private final class RulerReadoutLabel: UILabel {
    private static let padding = UIEdgeInsets(top: InkSpacing.xxs, left: InkSpacing.s, bottom: InkSpacing.xxs,
                                              right: InkSpacing.s)

    override init(frame: CGRect) {
        super.init(frame: frame)
        font = UIFont.monospacedDigitSystemFont(ofSize: UIFont.preferredFont(forTextStyle: .footnote).pointSize,
                                                weight: .semibold)
        textAlignment = .center
        layer.masksToBounds = true
        isUserInteractionEnabled = false
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func apply(_ theme: InkTheme) {
        textColor = theme.textPrimary
        backgroundColor = theme.surfaceRaised
        layer.borderColor = theme.border.resolvedColor(with: traitCollection).cgColor
        layer.borderWidth = 1
    }

    override func drawText(in rect: CGRect) {
        super.drawText(in: rect.inset(by: Self.padding))
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let s = super.sizeThatFits(size)
        let p = Self.padding
        let fitted = CGSize(width: s.width + p.left + p.right, height: s.height + p.top + p.bottom)
        layer.cornerRadius = fitted.height / 2
        return fitted
    }
}
