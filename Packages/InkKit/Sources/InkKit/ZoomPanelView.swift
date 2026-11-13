import UIKit

/// The zoom window's writing panel: a magnified copy of the zoom box, floating at the bottom of the canvas.
///
/// It only displays. Touches pass through to the `CanvasView` underneath, which maps Pencil input in
/// `inkFrame` through the panel's transform onto the page, so the ink lands in the box. The panel's buttons
/// are SwiftUI, laid over `controlsFrame` by the editor.
///
/// The ink is drawn like the canvas's own: a committed image of the box (rendered off the main thread by
/// the canvas) under a `LiveInkView` for the stroke being written.
final class ZoomPanelView: UIView {
    /// Panel padding around the ink area, and the width of the button column on the right.
    static let padding: CGFloat = 8
    static let controlsWidth: CGFloat = 48
    static let cornerRadius: CGFloat = 16
    static let inkCornerRadius: CGFloat = 10

    /// The ink area, in this view's coordinates.
    private(set) var inkFrame = CGRect.zero
    /// The button column, in this view's coordinates.
    private(set) var controlsFrame = CGRect.zero

    let liveView = LiveInkView()
    /// The box's strokes, rendered at `inkTransform` when `displayedTransform` was current.
    let committedLayer = CALayer()

    private let inkHost = UIView()
    private let paperLayer = CALayer()
    private let zoneLayer = CALayer()
    private let guideLayer = CAShapeLayer()
    private var displayedTransform = ViewTransform()
    private(set) var inkTransform = ViewTransform()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        layer.cornerRadius = Self.cornerRadius
        layer.cornerCurve = .continuous
        layer.borderWidth = 0.5
        layer.shadowOpacity = 0.10
        layer.shadowRadius = 6
        layer.shadowOffset = CGSize(width: 0, height: 8)

        inkHost.isUserInteractionEnabled = false
        inkHost.clipsToBounds = true
        inkHost.layer.cornerRadius = Self.inkCornerRadius
        inkHost.layer.cornerCurve = .continuous
        addSubview(inkHost)
        for sub in [paperLayer, zoneLayer, guideLayer, committedLayer] {
            sub.actions = ["contents": NSNull(), "transform": NSNull(), "bounds": NSNull(), "position": NSNull(),
                           "path": NSNull(), "frame": NSNull()]
            inkHost.layer.addSublayer(sub)
        }
        committedLayer.anchorPoint = .zero
        guideLayer.fillColor = nil
        guideLayer.lineWidth = 1
        guideLayer.lineDashPattern = [4, 4]
        inkHost.addSubview(liveView)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func apply(_ theme: InkTheme, traits: UITraitCollection) {
        backgroundColor = theme.surfaceRaised.resolvedColor(with: traits)
        layer.borderColor = theme.border.resolvedColor(with: traits).cgColor
        layer.shadowColor = theme.shadow.resolvedColor(with: traits).cgColor
        // Paper and ink look the same in both appearances.
        let paper = theme.paper.resolvedColor(with: UITraitCollection(userInterfaceStyle: .light))
        paperLayer.backgroundColor = paper.cgColor
        liveView.paperColor = paper.cgColor
        zoneLayer.backgroundColor = theme.accent.resolvedColor(with: traits).withAlphaComponent(0.06).cgColor
        guideLayer.strokeColor = theme.accent.resolvedColor(with: traits).withAlphaComponent(0.45).cgColor
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let p = Self.padding
        inkFrame = CGRect(x: p, y: p, width: max(bounds.width - 2 * p - Self.controlsWidth, 1),
                          height: max(bounds.height - 2 * p, 1))
        controlsFrame = CGRect(x: inkFrame.maxX, y: 0, width: bounds.width - inkFrame.maxX, height: bounds.height)
        inkHost.frame = inkFrame
        liveView.frame = inkHost.bounds
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        paperLayer.frame = inkHost.bounds
        committedLayer.bounds = inkHost.bounds
        committedLayer.position = .zero
        CATransaction.commit()
        layer.shadowPath = UIBezierPath(roundedRect: bounds, cornerRadius: Self.cornerRadius).cgPath
    }

    /// Shows `window`'s box at `transform` (page → ink-area coordinates): the line's baseline and the
    /// advance zone, and the committed image moved to match until it's rendered again.
    func show(_ window: ZoomWindow, at transform: ViewTransform) {
        inkTransform = transform
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let zoneX = transform.toView(CGPoint(x: window.advanceX, y: 0)).x
        zoneLayer.frame = CGRect(x: zoneX, y: 0, width: max(inkHost.bounds.maxX - zoneX, 0),
                                 height: inkHost.bounds.height)
        let path = CGMutablePath()
        let baseline = transform.toView(CGPoint(x: 0, y: window.lines.baseline(window.line))).y
        path.move(to: CGPoint(x: 0, y: baseline))
        path.addLine(to: CGPoint(x: inkHost.bounds.maxX, y: baseline))
        guideLayer.frame = inkHost.bounds
        guideLayer.path = path
        updateCommittedLayerTransform()
        CATransaction.commit()
    }

    /// A render of the box at `transform` is ready.
    func publish(_ image: CGImage?, transform: ViewTransform) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        committedLayer.contents = image
        displayedTransform = transform
        updateCommittedLayerTransform()
        CATransaction.commit()
        liveView.underlay = image
    }

    private func updateCommittedLayerTransform() {
        let k = inkTransform.scale / displayedTransform.scale
        committedLayer.setAffineTransform(displayedTransform == inkTransform ? .identity : CGAffineTransform(
            a: k, b: 0, c: 0, d: k,
            tx: inkTransform.offset.x - displayedTransform.offset.x * k,
            ty: inkTransform.offset.y - displayedTransform.offset.y * k
        ))
    }
}

/// The zoom box drawn on the page: its outline, a tab under its left edge to drag it by, and a knob on its
/// bottom-right corner to resize it. Display only; the canvas hit-tests the handles.
final class ZoomBoxOverlayView: UIView {
    /// The tab under the box, and the resize knob's radius, in view points.
    static let tabSize = CGSize(width: 36, height: 14)
    static let knobRadius: CGFloat = 7
    /// How far around a handle a touch still grabs it.
    static let touchSlop: CGFloat = 14

    private let outline = CAShapeLayer()
    private let tab = CAShapeLayer()
    private let knob = CAShapeLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        for shape in [outline, tab, knob] {
            shape.actions = ["path": NSNull()]
            layer.addSublayer(shape)
        }
        outline.lineWidth = 1.5
        knob.lineWidth = 1.5
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func apply(_ theme: InkTheme, traits: UITraitCollection) {
        let accent = theme.accent.resolvedColor(with: traits)
        outline.strokeColor = accent.cgColor
        outline.fillColor = accent.withAlphaComponent(0.06).cgColor
        tab.fillColor = accent.cgColor
        knob.strokeColor = accent.cgColor
        knob.fillColor = theme.paper.resolvedColor(with: UITraitCollection(userInterfaceStyle: .light)).cgColor
    }

    /// The box in view coordinates.
    func show(box rect: CGRect) {
        outline.path = CGPath(roundedRect: rect, cornerWidth: 3, cornerHeight: 3, transform: nil)
        tab.path = UIBezierPath(roundedRect: Self.tabRect(for: rect), byRoundingCorners: [.bottomLeft, .bottomRight],
                                cornerRadii: CGSize(width: 5, height: 5)).cgPath
        let k = Self.knobRadius
        knob.path = CGPath(ellipseIn: CGRect(x: rect.maxX - k, y: rect.maxY - k, width: 2 * k, height: 2 * k),
                           transform: nil)
    }

    static func tabRect(for box: CGRect) -> CGRect {
        CGRect(x: box.minX, y: box.maxY, width: tabSize.width, height: tabSize.height)
    }

    enum Handle { case move, resize }

    /// The handle of a box at `box` (view coordinates) under `point`, if any.
    static func handle(at point: CGPoint, box: CGRect) -> Handle? {
        let s = touchSlop
        let corner = CGPoint(x: box.maxX, y: box.maxY)
        if point.distance(to: corner) <= knobRadius + s {
            return .resize
        }
        // Only below the box, so writing along the box's bottom edge never grabs it.
        var tab = tabRect(for: box).insetBy(dx: -s, dy: -s)
        tab.size.height -= box.maxY - tab.minY
        tab.origin.y = box.maxY
        if tab.contains(point) {
            return .move
        }
        return nil
    }
}
