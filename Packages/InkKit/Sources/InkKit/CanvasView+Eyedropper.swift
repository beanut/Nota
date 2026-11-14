import QuartzCore
import UIKit

// MARK: - Eyedropper sampling

extension CanvasView {
    /// The colour shown at `point` (view coordinates): the page's paper, template and ink as they're
    /// drawn right now, or the desk off the page. Nil outside the view.
    func sampledColor(at point: CGPoint) -> PenColor? {
        guard bounds.contains(point) else { return nil }
        return Eyedropper.sample(layer, at: point, scale: window?.screen.scale ?? traitCollection.displayScale)
    }
}

enum Eyedropper {
    /// The sRGB colour of the device pixel at `point` (in `layer`'s coordinates, `scale` pixels per point)
    /// of `layer` and its sublayers, composited over white.
    static func sample(_ layer: CALayer, at point: CGPoint, scale: CGFloat = 1) -> PenColor? {
        var pixel = [UInt8](repeating: 0, count: 4)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let drawn: Bool = pixel.withUnsafeMutableBytes { buffer in
            guard let ctx = CGContext(data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8,
                                      bytesPerRow: 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
            // Core Graphics' origin is bottom left; a layer draws top-down.
            ctx.translateBy(x: 0, y: 1)
            ctx.scaleBy(x: 1, y: -1)
            let s = max(scale, 1)
            ctx.scaleBy(x: s, y: s)
            ctx.translateBy(x: -(point.x * s).rounded(.down) / s, y: -(point.y * s).rounded(.down) / s)
            layer.render(in: ctx)
            return true
        }
        guard drawn else { return nil }
        return PenColor(rgb: UInt32(pixel[0]) << 16 | UInt32(pixel[1]) << 8 | UInt32(pixel[2]))
    }
}
