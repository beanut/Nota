import UIKit

/// Draws a `LaserTrail` over a page: a glowing line in the theme's laser colour (`InkTheme.laser`) with a
/// bright dot at its head, fading as it ages. It has nothing to do with the ink: it's its own lightweight
/// layer over everything else, redrawn by a display link only while something is showing, and never
/// touches the committed or live ink layers.
///
/// Used twice: over the canvas, where the laser tool draws (`CanvasView+Laser`), and over the page on an
/// external display (`PageMirrorView`). Each maps the trail's page-space points through its own transform.
final class LaserView: UIView {
    var trail = LaserTrail() {
        didSet {
            runIfNeeded()
            setNeedsDisplay()
        }
    }

    /// The theme's laser colour (`InkTheme.laser`).
    var color = InkTheme.standardLaser.uiColor
    /// Maps the trail's page-space points into this view. Read at every frame, so it follows panning and zooming.
    var pageTransform: () -> ViewTransform = { ViewTransform() }
    /// Called after each frame prunes what has faded, with the trail as it is now.
    var onFrame: ((LaserTrail) -> Void)?
    /// Line widths in view points: the soft glow, the coloured line and its bright core.
    static let glowWidth: CGFloat = 14
    static let lineWidth: CGFloat = 4.5
    static let coreWidth: CGFloat = 1.5
    static let dotRadius: CGFloat = 8
    /// Segments are drawn in this many opacity steps, so a long trail is a handful of paths, not hundreds.
    static let opacitySteps = 12

    private var link: CADisplayLink?

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

    override func willMove(toWindow newWindow: UIWindow?) {
        super.willMove(toWindow: newWindow)
        if newWindow == nil {
            stop()
        }
    }

    private func runIfNeeded() {
        if trail.isEmpty {
            stop()
        } else if link == nil, window != nil || superview != nil {
            let link = CADisplayLink(target: DisplayLinkTarget(self), selector: #selector(DisplayLinkTarget.step))
            link.add(to: .main, forMode: .common)
            self.link = link
        }
    }

    private func stop() {
        link?.invalidate()
        link = nil
    }

    fileprivate func step() {
        var pruned = trail
        pruned.prune(now: CACurrentMediaTime())
        if pruned != trail {
            trail = pruned // also stops the link once it's empty
        } else {
            setNeedsDisplay()
        }
        onFrame?(trail)
    }

    override func draw(_: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext(), !trail.points.isEmpty else { return }
        Self.draw(trail, color: color, transform: pageTransform(), now: CACurrentMediaTime(), in: ctx)
    }

    /// Draws `trail` as it looks at `now`, mapped into `ctx` through `transform`.
    static func draw(_ trail: LaserTrail, color: UIColor, transform: ViewTransform, now: TimeInterval, in ctx: CGContext) {
        let points = trail.points
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        if trail.mode == .trail, points.count > 1 {
            // One path per opacity step: each segment takes the opacity of its older end.
            let paths = (0 ... opacitySteps).map { _ in CGMutablePath() }
            for i in points.indices.dropFirst() where !points[i].startsLine {
                let alpha = trail.opacity(of: points[i - 1], now: now)
                guard alpha > 0 else { continue }
                let step = Int((alpha * CGFloat(opacitySteps)).rounded(.up))
                paths[step].move(to: transform.toView(points[i - 1].location))
                paths[step].addLine(to: transform.toView(points[i].location))
            }
            for (step, path) in paths.enumerated() where !path.isEmpty {
                let alpha = CGFloat(step) / CGFloat(opacitySteps)
                for (width, ink) in [(glowWidth, color.withAlphaComponent(0.22 * alpha)),
                                     (lineWidth, color.withAlphaComponent(alpha)),
                                     (coreWidth, UIColor.white.withAlphaComponent(0.85 * alpha))] {
                    ctx.addPath(path)
                    ctx.setLineWidth(width)
                    ctx.setStrokeColor(ink.cgColor)
                    ctx.strokePath()
                }
            }
        }
        guard let head = trail.head else { return }
        let alpha = trail.headOpacity(now: now)
        guard alpha > 0 else { return }
        let p = transform.toView(head.location)
        let r = dotRadius
        ctx.setFillColor(color.withAlphaComponent(0.25 * alpha).cgColor)
        ctx.fillEllipse(in: CGRect(x: p.x - 2 * r, y: p.y - 2 * r, width: 4 * r, height: 4 * r))
        ctx.setFillColor(color.withAlphaComponent(alpha).cgColor)
        ctx.fillEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r))
        ctx.setFillColor(UIColor.white.withAlphaComponent(0.85 * alpha).cgColor)
        ctx.fillEllipse(in: CGRect(x: p.x - r / 3, y: p.y - r / 3, width: 2 * r / 3, height: 2 * r / 3))
    }
}

/// Holds the laser view weakly, so its display link doesn't keep it alive.
private final class DisplayLinkTarget {
    weak var view: LaserView?

    init(_ view: LaserView) {
        self.view = view
    }

    @objc func step(_ link: CADisplayLink) {
        guard let view else {
            link.invalidate()
            return
        }
        MainActor.assumeIsolated { view.step() }
    }
}
