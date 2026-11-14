import CoreGraphics
import Foundation
@testable import InkKit
import Testing

@Suite("Brush editor parameters")
struct BrushParameterTests {
    /// A brush with every optional feature on, so every parameter is shown and does something.
    private static let everything: BrushDescriptor = {
        var b = BrushDescriptor.fountainPen
        b.pressureOpacity = .init(amount: 0.5, exponent: 1.2)
        b.tilt = .standard
        b.velocity = .init(amount: 0.4, exponent: 1)
        b.taper = .init(startLength: 10, endLength: 10, minimumScale: 0.2)
        b.dash = .init(on: 2, off: 1)
        b.jitter = .init(size: 0.1, angle: 0.1, scatter: 0.1, opacity: 0.1, seed: 3)
        return b
    }()

    private static var grain: BrushDescriptor {
        var b = everything
        b.texture = .grain(scale: 1, contrast: 0.5, seed: 7)
        return b
    }

    private static var bristle: BrushDescriptor {
        var b = everything
        b.texture = .bristle(count: 10, spread: 1)
        return b
    }

    @Test("Ids are unique")
    func uniqueIDs() {
        let ids = BrushParameter.all.map(\.id)
        #expect(Set(ids).count == ids.count)
        for section in BrushParameter.Section.allCases where section != .look {
            #expect(!BrushParameter.parameters(in: section).isEmpty, "\(section.rawValue)")
        }
    }

    @Test("Every slider value, ends and middle, leaves a legal brush")
    func settersStayLegal() {
        for base in [Self.everything, Self.grain, Self.bristle, BrushDescriptor.pen, BrushDescriptor.highlighter] {
            for parameter in BrushParameter.all {
                let r = parameter.range
                for value in [r.lowerBound, (r.lowerBound + r.upperBound) / 2, r.upperBound, -1e9, 1e9, .nan] {
                    let b = parameter.setting(value, on: base)
                    #expect(b.clamped() == b, "\(parameter.id) = \(value)")
                }
            }
        }
    }

    @Test("A value set is the value read back")
    func roundTrip() {
        for base in [Self.everything, Self.grain, Self.bristle] {
            for parameter in BrushParameter.all where parameter.isShown(base) {
                let r = parameter.range
                for t in [0.0, 0.3, 1.0] {
                    var value = r.lowerBound + (r.upperBound - r.lowerBound) * t
                    if parameter.unit == .integer {
                        value = value.rounded()
                    }
                    if parameter.id == "tilt.fullAltitude" {
                        value = min(value, Double(base.tilt.startAltitude) - 1)
                    }
                    let b = parameter.setting(value, on: base)
                    #expect(abs(parameter.get(b) - value) < 1e-6, "\(parameter.id) = \(value) read \(parameter.get(b))")
                }
            }
        }
    }

    @Test("Every number in a descriptor has a slider")
    func coversTheDescriptor() throws {
        // Each JSON leaf that's a number, by path; the editor must list one parameter for each.
        let json = try JSONSerialization.jsonObject(with: Self.grain.jsonData()) as? [String: Any]
        let bristleJSON = try JSONSerialization.jsonObject(with: Self.bristle.jsonData()) as? [String: Any]
        var leaves = Set<String>()
        func walk(_ value: Any, _ path: String) {
            if let dict = value as? [String: Any] {
                for (k, v) in dict {
                    walk(v, path.isEmpty ? k : "\(path).\(k)")
                }
            } else if value is NSNumber, CFGetTypeID(value as CFTypeRef) != CFBooleanGetTypeID() {
                leaves.insert(path)
            }
        }
        try walk(#require(json), "")
        try walk(#require(bristleJSON), "")
        // How the editor names them.
        let mapping: [String: String] = [
            "tip.ellipse.aspect": "tip.aspect", "tip.ellipse.angle": "tip.angle",
            "texture.grain.scale": "grain.scale", "texture.grain.contrast": "grain.contrast",
            "texture.grain.seed": "grain.seed", "texture.bristle.count": "bristle.count",
            "texture.bristle.spread": "bristle.spread"
        ]
        let ids = Set(BrushParameter.all.map(\.id))
        for leaf in leaves {
            #expect(ids.contains(mapping[leaf] ?? leaf), "no slider for \(leaf)")
        }
        // `size` is an array: upper bound and the ratio of the lower one.
        #expect(ids.isSuperset(of: ["size.upper", "size.ratio"]))
    }

    @Test("Values read the way the editor shows them")
    func text() throws {
        let width = try #require(BrushParameter.all.first { $0.id == "size.upper" })
        #expect(width.text(for: .pen) == "4.0 pt")
        let ratio = try #require(BrushParameter.all.first { $0.id == "size.ratio" })
        #expect(ratio.text(for: .pen) == "25%")
        let angle = try #require(BrushParameter.all.first { $0.id == "tip.angle" })
        #expect(angle.text(for: .fountainPen) == "-34°")
        // Changing the width keeps the brush's own minimum-width ratio.
        let wide = width.setting(8, on: .pen)
        #expect(wide.size == 2 ... 8)
    }

    @Test("Hidden parameters are the ones that do nothing")
    func shown() throws {
        let aspect = try #require(BrushParameter.all.first { $0.id == "tip.aspect" })
        #expect(!aspect.isShown(.pen) && aspect.isShown(.fountainPen))
        let dashLength = try #require(BrushParameter.all.first { $0.id == "dash.on" })
        #expect(!dashLength.isShown(.pen) && dashLength.isShown(.dashedPen))
        let grainSize = try #require(BrushParameter.all.first { $0.id == "grain.scale" })
        #expect(grainSize.isShown(.pencil) && !grainSize.isShown(.pen))
        // Setting a hidden parameter changes nothing.
        #expect(aspect.setting(0.5, on: .pen) == .pen)
    }
}
