import UIKit

/// How a picture is being cropped: to a rectangle dragged by its edges and corners, or to an outline drawn
/// around the part to keep.
public enum ImageCropMode: String, CaseIterable, Identifiable, Sendable {
    case rectangle, freehand

    public var id: String {
        rawValue
    }
}

/// What the crop bar shows while a picture is cropped.
struct ImageCropState: Equatable {
    var mode: ImageCropMode
    /// Whether the crop being edited shows less than the whole picture.
    var isCropped: Bool
}

/// The pure geometry of cropping, in unit image space (see `ImageObject`), so it can be tested without a view.
enum ImageCropGeometry {
    /// A crop rectangle's grip: a corner, an edge, or the middle (moving the whole rectangle).
    struct Grip: Equatable {
        /// -1 for the left (or top) edge, 1 for the right (or bottom), 0 for neither.
        var x: Int
        var y: Int

        static let move = Grip(x: 0, y: 0)

        static let all: [Grip] = [Grip(x: -1, y: -1), Grip(x: 0, y: -1), Grip(x: 1, y: -1), Grip(x: 1, y: 0),
                                  Grip(x: 1, y: 1), Grip(x: 0, y: 1), Grip(x: -1, y: 1), Grip(x: -1, y: 0)]

        /// Where the grip sits on `rect`.
        func point(on rect: CGRect) -> CGPoint {
            CGPoint(x: x < 0 ? rect.minX : x > 0 ? rect.maxX : rect.midX,
                    y: y < 0 ? rect.minY : y > 0 ? rect.maxY : rect.midY)
        }
    }

    /// `crop` with `grip` dragged by `delta` (unit image space), kept inside the picture and no smaller than
    /// `ImageObject.minimumCrop`. Moving keeps the size; an edge or corner moves only its own sides.
    static func dragging(_ grip: Grip, of crop: CGRect, by delta: CGVector) -> CGRect {
        let minimum = ImageObject.minimumCrop
        if grip == .move {
            let x = min(max(crop.minX + delta.dx, 0), 1 - crop.width)
            let y = min(max(crop.minY + delta.dy, 0), 1 - crop.height)
            return CGRect(x: x, y: y, width: crop.width, height: crop.height)
        }
        var minX = crop.minX, maxX = crop.maxX, minY = crop.minY, maxY = crop.maxY
        if grip.x < 0 {
            minX = min(max(minX + delta.dx, 0), maxX - minimum)
        } else if grip.x > 0 {
            maxX = max(min(maxX + delta.dx, 1), minX + minimum)
        }
        if grip.y < 0 {
            minY = min(max(minY + delta.dy, 0), maxY - minimum)
        } else if grip.y > 0 {
            maxY = max(min(maxY + delta.dy, 1), minY + minimum)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// A freehand outline as a crop mask: nil if it's too small to keep (under `minimumCrop` across or down)
    /// or has too few points. Points outside the picture are pulled onto its edge.
    static func mask(from outline: [CGPoint]) -> [CGPoint]? {
        let clamped = outline.map { CGPoint(x: min(max($0.x, 0), 1), y: min(max($0.y, 0), 1)) }
        let bounds = ImageObject.bounds(of: clamped)
        guard clamped.count >= 3, !bounds.isNull, bounds.width >= ImageObject.minimumCrop,
              bounds.height >= ImageObject.minimumCrop else { return nil }
        return clamped
    }
}

/// The picture being cropped, over the canvas: the whole picture dimmed, the part kept at full strength,
/// and the crop's rectangle with grips at its corners and edges (or the outline being drawn). It takes every
/// touch while it's up, Pencil and finger alike; the crop bar (`ImageCropBar`) finishes it.
final class ImageCropView: UIView {
    /// The picture as it was when cropping began.
    let original: ImageObject
    private(set) var mode: ImageCropMode
    /// The crop being edited, in unit image space.
    private(set) var crop: CGRect
    private(set) var outlineMask: [CGPoint]?
    /// Called after every change, for the crop bar.
    var onChange: (() -> Void)?

    /// Unit image space → view points.
    private var unitToView = CGAffineTransform.identity
    /// The picture, in unit image space under `pictureLayer`'s transform: whole and dimmed, then the part
    /// kept at full strength through a mask. Layers, so a drag only moves a mask instead of redrawing the
    /// picture (and the touches keep coming in at full rate).
    private let pictureLayer = CALayer()
    private let dimmedLayer = CALayer()
    private let keptLayer = CALayer()
    private let keptMask = CAShapeLayer()
    private let wholeLayer = CAShapeLayer()
    private let keptOutlineLayer = CAShapeLayer()
    private let gripsLayer = CAShapeLayer()
    private let traceLayer = CAShapeLayer()
    private let accent: UIColor
    private let knobFill: UIColor
    /// A grip being dragged: which, where the touch began (unit image space) and the crop then.
    private struct CropDrag {
        let grip: ImageCropGeometry.Grip
        let start: CGPoint
        let crop: CGRect
    }

    private var drag: CropDrag?
    private var outline: [CGPoint] = []

    /// How far from a grip (view points) a touch still takes it.
    static let gripReach: CGFloat = 24

    var objectID: UUID {
        original.id
    }

    /// `accent` draws the crop and its grips; `knobFill` (the paper) fills the grips.
    init(image: ImageObject, mode: ImageCropMode, accent: UIColor, knobFill: UIColor) {
        original = image
        self.mode = mode
        crop = image.crop
        outlineMask = image.mask
        self.accent = accent
        self.knobFill = knobFill
        super.init(frame: .zero)
        isOpaque = false
        backgroundColor = .clear
        isMultipleTouchEnabled = false
        pictureLayer.anchorPoint = .zero
        pictureLayer.bounds = ImageObject.unitRect
        for sublayer in [dimmedLayer, keptLayer] {
            sublayer.frame = ImageObject.unitRect
            sublayer.contentsGravity = .resize
            pictureLayer.addSublayer(sublayer)
        }
        dimmedLayer.opacity = Float(0.3 * image.opacity)
        keptLayer.opacity = Float(image.opacity)
        keptLayer.mask = keptMask
        layer.addSublayer(pictureLayer)
        for (shape, width) in [(wholeLayer, 1.0), (keptOutlineLayer, 2.0), (traceLayer, 2.0), (gripsLayer, 2.0)] {
            shape.fillColor = nil
            shape.strokeColor = accent.cgColor
            shape.lineWidth = width
            layer.addSublayer(shape)
        }
        wholeLayer.strokeColor = accent.withAlphaComponent(0.35).cgColor
        gripsLayer.fillColor = knobFill.cgColor
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// The picture with the crop as it stands.
    var result: ImageObject {
        original.cropped(to: crop, mask: mode == .freehand ? outlineMask : nil)
    }

    var state: ImageCropState {
        ImageCropState(mode: mode, isCropped: result.isCropped)
    }

    /// Follows the canvas to `transform` (canvas space → view).
    func place(at transform: ViewTransform, screenScale: CGFloat) {
        let image = original.imageRect
        unitToView = CGAffineTransform(a: image.width, b: 0, c: 0, d: image.height, tx: image.minX, ty: image.minY)
            .concatenating(original.transform).concatenating(transform.affine)
        let shown = max(image.width, image.height) * transform.scale * screenScale
        let bitmap = ImageAssets.shared.image(for: original.asset, pixelSize: shown, waits: true)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pictureLayer.position = .zero
        pictureLayer.setAffineTransform(unitToView)
        dimmedLayer.contents = bitmap
        keptLayer.contents = bitmap
        CATransaction.commit()
        updateMask()
        refreshOverlay()
    }

    /// Shows the part kept through `keptLayer`'s mask (unit image space).
    private func updateMask() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        keptMask.path = keptUnitPath()
        CATransaction.commit()
    }

    func setMode(_ newMode: ImageCropMode) {
        guard newMode != mode else { return }
        mode = newMode
        if newMode == .rectangle {
            outlineMask = nil
        }
        changed()
    }

    /// Back to the whole picture.
    func reset() {
        crop = ImageObject.unitRect
        outlineMask = nil
        changed()
    }

    private func changed() {
        updateMask()
        refreshOverlay()
        onChange?()
    }

    // MARK: Drawing

    /// The whole picture's edge (faint), what's kept (dashed when freehand), the grips and the outline being
    /// drawn, in view points, over the picture.
    private func refreshOverlay() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        wholeLayer.path = CGPath(rect: ImageObject.unitRect, transform: &unitToView)
        keptOutlineLayer.path = keptUnitPath().copy(using: &unitToView)
        keptOutlineLayer.lineDashPattern = mode == .freehand ? [6, 4] : nil
        let grips = CGMutablePath()
        if mode == .rectangle {
            let r: CGFloat = 6
            for grip in ImageCropGeometry.Grip.all {
                let p = grip.point(on: crop).applying(unitToView)
                grips.addEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r))
            }
        }
        gripsLayer.path = grips
        let trace = CGMutablePath()
        if mode == .freehand, outline.count >= 2 {
            trace.addLines(between: outline, transform: unitToView)
        }
        traceLayer.path = trace
    }

    /// The part kept, in unit image space: the freehand outline, or the crop rectangle.
    private func keptUnitPath() -> CGPath {
        if mode == .freehand, let outlineMask {
            let path = CGMutablePath()
            path.addLines(between: outlineMask)
            path.closeSubpath()
            return path
        }
        return CGPath(rect: crop, transform: nil)
    }

    // MARK: Touches

    /// A drag here is the crop's: no page swipe, pan, pinch or navigation back-swipe from the views around it
    /// (iPadOS 26 recognises a back-swipe anywhere in a navigation stack's content). Taps still reach the
    /// crop bar.
    override func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
        g.view === self || !(g is UIPanGestureRecognizer || g is UISwipeGestureRecognizer || g is UIPinchGestureRecognizer)
    }

    private func unitPoint(_ touch: UITouch) -> CGPoint {
        touch.location(in: self).applying(unitToView.inverted())
    }

    override func touchesBegan(_ touches: Set<UITouch>, with _: UIEvent?) {
        guard let touch = touches.first else { return }
        let p = unitPoint(touch)
        switch mode {
        case .rectangle:
            let view = touch.location(in: self)
            let nearest = ImageCropGeometry.Grip.all.min {
                $0.point(on: crop).applying(unitToView).distance(to: view) < $1.point(on: crop).applying(unitToView).distance(to: view)
            }
            if let nearest, nearest.point(on: crop).applying(unitToView).distance(to: view) <= Self.gripReach {
                drag = CropDrag(grip: nearest, start: p, crop: crop)
            } else if crop.contains(p) {
                drag = CropDrag(grip: .move, start: p, crop: crop)
            }
        case .freehand:
            outline = [p]
            refreshOverlay()
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first else { return }
        let p = unitPoint(touch)
        switch mode {
        case .rectangle:
            guard let drag else { return }
            crop = ImageCropGeometry.dragging(drag.grip, of: drag.crop, by: CGVector(dx: p.x - drag.start.x, dy: p.y - drag.start.y))
            changed()
        case .freehand:
            guard !outline.isEmpty else { return }
            // Every sample since the last event, not only the latest, so the outline follows the finger.
            let samples = event?.coalescedTouches(for: touch) ?? [touch]
            outline.append(contentsOf: samples.map(unitPoint))
            refreshOverlay()
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with _: UIEvent?) {
        drag = nil
        if mode == .freehand, !outline.isEmpty {
            if let touch = touches.first {
                outline.append(unitPoint(touch))
            }
            if let traced = ImageCropGeometry.mask(from: outline) {
                outlineMask = traced
                crop = ImageObject.clampedCrop(ImageObject.bounds(of: traced))
            }
            outline = []
            changed()
        }
    }

    override func touchesCancelled(_: Set<UITouch>, with _: UIEvent?) {
        drag = nil
        outline = []
        refreshOverlay()
    }

    /// Applies a freehand outline (unit image space) as if it had been drawn, for tests.
    func trace(_ points: [CGPoint]) {
        setMode(.freehand)
        if let traced = ImageCropGeometry.mask(from: points) {
            outlineMask = traced
            crop = ImageObject.clampedCrop(ImageObject.bounds(of: traced))
        }
        changed()
    }

    /// Drags `grip` by `delta` (unit image space), for tests.
    func drag(_ grip: ImageCropGeometry.Grip, by delta: CGVector) {
        setMode(.rectangle)
        crop = ImageCropGeometry.dragging(grip, of: crop, by: delta)
        changed()
    }
}
