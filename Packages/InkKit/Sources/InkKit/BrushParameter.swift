import CoreGraphics
import Foundation

/// One numeric `BrushDescriptor` parameter as the brush editor shows it: a label, a slider range inside the
/// parameter's legal range, how its value reads, and how to get and set it.
///
/// Setters always leave the brush legal (`clamped()` changes nothing), so the editor can never make a brush
/// the renderer can't draw, and the same list is the manual-edit surface for model-made brushes.
struct BrushParameter: Identifiable {
    enum Section: String, CaseIterable, Identifiable {
        case nib = "Nib"
        case pressure = "Pressure"
        case tilt = "Tilt"
        case speed = "Speed and Ink Flow"
        case ends = "Ends"
        case stroke = "Stroke"
        case texture = "Texture"
        case jitter = "Jitter"
        case look = "Opacity"

        var id: String {
            rawValue
        }
    }

    enum Unit {
        /// Canvas points, one decimal.
        case points
        /// 0…1 shown as a percentage.
        case percent
        /// Degrees.
        case degrees
        /// A plain number, two decimals.
        case number
        /// Multiples of the nib width, two decimals.
        case widths
        /// A whole number.
        case integer
    }

    let id: String
    let label: String
    let section: Section
    /// The slider's range, inside the legal range.
    let range: ClosedRange<Double>
    let unit: Unit
    /// Whether the parameter does anything for this brush (an ellipse's aspect, a grain's contrast).
    var isShown: (BrushDescriptor) -> Bool = { _ in true }
    let get: (BrushDescriptor) -> Double
    let apply: (inout BrushDescriptor, Double) -> Void

    /// Sets the parameter and returns the brush, clamped.
    func setting(_ value: Double, on brush: BrushDescriptor) -> BrushDescriptor {
        var b = brush
        apply(&b, min(max(value.isNaN ? range.lowerBound : value, range.lowerBound), range.upperBound))
        return b.clamped()
    }

    /// The value as the editor shows it.
    func text(for brush: BrushDescriptor) -> String {
        let v = get(brush)
        return switch unit {
        case .points: String(format: "%.1f pt", v)
        case .percent: "\(Int((v * 100).rounded()))%"
        case .degrees: "\(Int(v.rounded()))°"
        case .number: String(format: "%.2f", v)
        case .widths: String(format: "%.2f×", v)
        case .integer: "\(Int(v.rounded()))"
        }
    }
}

extension BrushParameter {
    /// Every numeric parameter, in editor order. The discrete ones (tip shape, tilt on/off, texture kind,
    /// blend mode) are pickers and toggles in the editor itself.
    static let all: [BrushParameter] = nib + pressure + tilt + speed + ends + stroke + texture + jitter + look

    static func parameters(in section: Section) -> [BrushParameter] {
        all.filter { $0.section == section }
    }

    // MARK: Nib

    private static let nib: [BrushParameter] = [
        BrushParameter(id: "size.upper", label: "Default width", section: .nib, range: 0.5 ... 60, unit: .points,
                       get: { Double($0.size.upperBound) },
                       apply: { b, v in
                           let ratio = b.size.upperBound > 0 ? b.size.lowerBound / b.size.upperBound : 1
                           b.size = CGFloat(v) * ratio ... CGFloat(v)
                       }),
        BrushParameter(id: "size.ratio", label: "Minimum width", section: .nib, range: 0 ... 1, unit: .percent,
                       get: { $0.size.upperBound > 0 ? Double($0.size.lowerBound / $0.size.upperBound) : 1 },
                       apply: { b, v in b.size = b.size.upperBound * CGFloat(v) ... b.size.upperBound }),
        BrushParameter(id: "tip.aspect", label: "Nib roundness", section: .nib, range: 0.05 ... 1, unit: .percent,
                       isShown: { !$0.tip.isRound },
                       get: {
                           if case let .ellipse(aspect, _) = $0.tip {
                               Double(aspect)
                           } else {
                               1
                           }
                       },
                       apply: { b, v in
                           if case let .ellipse(_, angle) = b.tip {
                               b.tip = .ellipse(aspect: CGFloat(v), angle: angle)
                           }
                       }),
        BrushParameter(id: "tip.angle", label: "Nib angle", section: .nib, range: -180 ... 180, unit: .degrees,
                       isShown: { !$0.tip.isRound },
                       get: {
                           if case let .ellipse(_, angle) = $0.tip {
                               Double(angle) * 180 / .pi
                           } else {
                               0
                           }
                       },
                       apply: { b, v in
                           if case let .ellipse(aspect, _) = b.tip {
                               b.tip = .ellipse(aspect: aspect, angle: CGFloat(v) * .pi / 180)
                           }
                       })
    ]

    // MARK: Pressure

    private static let pressure: [BrushParameter] = [
        curve("pressure", "Pressure → width", .pressure, \.pressure),
        curve("pressureOpacity", "Pressure → opacity", .pressure, \.pressureOpacity)
    ].flatMap { $0 }

    // MARK: Tilt

    private static let tilt: [BrushParameter] = {
        func shown(_ b: BrushDescriptor) -> Bool {
            b.tilt.enabled
        }
        return [
            BrushParameter(id: "tilt.startAltitude", label: "Starts below", section: .tilt, range: 1 ... 89,
                           unit: .degrees, isShown: shown, get: { Double($0.tilt.startAltitude) },
                           apply: { b, v in
                               b.tilt.startAltitude = CGFloat(v)
                               b.tilt.fullAltitude = min(b.tilt.fullAltitude, CGFloat(v) - 1)
                           }),
            BrushParameter(id: "tilt.fullAltitude", label: "Full at", section: .tilt, range: 0 ... 88, unit: .degrees,
                           isShown: shown, get: { Double($0.tilt.fullAltitude) },
                           apply: { b, v in b.tilt.fullAltitude = min(CGFloat(v), b.tilt.startAltitude - 1) }),
            BrushParameter(id: "tilt.length", label: "Length", section: .tilt, range: 0 ... 8, unit: .widths,
                           isShown: shown, get: { Double($0.tilt.length) },
                           apply: { b, v in b.tilt.length = CGFloat(v) }),
            BrushParameter(id: "tilt.breadth", label: "Breadth", section: .tilt, range: 0 ... 4, unit: .widths,
                           isShown: shown, get: { Double($0.tilt.breadth) },
                           apply: { b, v in b.tilt.breadth = CGFloat(v) }),
            BrushParameter(id: "tilt.opacityLoss", label: "Lightens by", section: .tilt, range: 0 ... 1,
                           unit: .percent, isShown: shown, get: { Double($0.tilt.opacityLoss) },
                           apply: { b, v in b.tilt.opacityLoss = CGFloat(v) }),
            BrushParameter(id: "tilt.contactShift", label: "Contact shift", section: .tilt, range: 0 ... 1,
                           unit: .percent, isShown: shown, get: { Double($0.tilt.contactShift) },
                           apply: { b, v in b.tilt.contactShift = CGFloat(v) })
        ]
    }()

    // MARK: Speed

    private static let speed: [BrushParameter] = curve("velocity", "Thins when fast", .speed, \.velocity) + [
        BrushParameter(id: "wetness", label: "Wetness", section: .speed, range: 0 ... 1, unit: .percent,
                       get: { Double($0.wetness) }, apply: { b, v in b.wetness = CGFloat(v) })
    ]

    // MARK: Ends

    private static let ends: [BrushParameter] = [
        BrushParameter(id: "taper.startLength", label: "Start taper", section: .ends, range: 0 ... 100,
                       unit: .points, get: { Double($0.taper.startLength) },
                       apply: { b, v in b.taper.startLength = CGFloat(v) }),
        BrushParameter(id: "taper.endLength", label: "End taper", section: .ends, range: 0 ... 100, unit: .points,
                       get: { Double($0.taper.endLength) }, apply: { b, v in b.taper.endLength = CGFloat(v) }),
        BrushParameter(id: "taper.minimumScale", label: "Tapers to", section: .ends, range: 0 ... 1, unit: .percent,
                       isShown: { $0.taper.startLength > 0 || $0.taper.endLength > 0 },
                       get: { Double($0.taper.minimumScale) }, apply: { b, v in b.taper.minimumScale = CGFloat(v) })
    ]

    // MARK: Stroke

    private static let stroke: [BrushParameter] = [
        BrushParameter(id: "smoothing", label: "Smoothing", section: .stroke, range: 0 ... 0.95, unit: .percent,
                       get: { Double($0.smoothing) }, apply: { b, v in b.smoothing = CGFloat(v) }),
        BrushParameter(id: "spacing", label: "Stamp spacing", section: .stroke, range: 0 ... 4, unit: .widths,
                       get: { Double($0.spacing) }, apply: { b, v in b.spacing = CGFloat(v) }),
        BrushParameter(id: "dash.off", label: "Dash gap", section: .stroke, range: 0 ... 20, unit: .widths,
                       get: { Double($0.dash.off) }, apply: { b, v in b.dash.off = CGFloat(v) }),
        BrushParameter(id: "dash.on", label: "Dash length", section: .stroke, range: 0.05 ... 20, unit: .widths,
                       isShown: { $0.dash.off > 0 }, get: { Double($0.dash.on) },
                       apply: { b, v in b.dash.on = CGFloat(v) })
    ]

    // MARK: Texture

    private static let texture: [BrushParameter] = {
        func isGrain(_ b: BrushDescriptor) -> Bool {
            b.texture.kind == .grain
        }
        func isBristle(_ b: BrushDescriptor) -> Bool {
            b.texture.kind == .bristle
        }
        return [
            BrushParameter(id: "grain.scale", label: "Grain size", section: .texture, range: 0.25 ... 8, unit: .widths,
                           isShown: isGrain,
                           get: {
                               if case let .grain(scale, _, _) = $0.texture {
                                   Double(scale)
                               } else {
                                   1
                               }
                           },
                           apply: { b, v in
                               if case let .grain(_, contrast, seed) = b.texture {
                                   b.texture = .grain(scale: CGFloat(v), contrast: contrast, seed: seed)
                               }
                           }),
            BrushParameter(id: "grain.contrast", label: "Grain contrast", section: .texture, range: 0 ... 1,
                           unit: .percent, isShown: isGrain,
                           get: {
                               if case let .grain(_, contrast, _) = $0.texture {
                                   Double(contrast)
                               } else {
                                   1
                               }
                           },
                           apply: { b, v in
                               if case let .grain(scale, _, seed) = b.texture {
                                   b.texture = .grain(scale: scale, contrast: CGFloat(v), seed: seed)
                               }
                           }),
            BrushParameter(id: "grain.seed", label: "Grain pattern", section: .texture, range: 0 ... 999,
                           unit: .integer, isShown: isGrain,
                           get: {
                               if case let .grain(_, _, seed) = $0.texture {
                                   Double(seed)
                               } else {
                                   0
                               }
                           },
                           apply: { b, v in
                               if case let .grain(scale, contrast, _) = b.texture {
                                   b.texture = .grain(scale: scale, contrast: contrast, seed: UInt32(v.rounded()))
                               }
                           }),
            BrushParameter(id: "bristle.count", label: "Bristles", section: .texture, range: 1 ... 64, unit: .integer,
                           isShown: isBristle,
                           get: {
                               if case let .bristle(count, _) = $0.texture {
                                   Double(count)
                               } else {
                                   8
                               }
                           },
                           apply: { b, v in
                               if case let .bristle(_, spread) = b.texture {
                                   b.texture = .bristle(count: Int(v.rounded()), spread: spread)
                               }
                           }),
            BrushParameter(id: "bristle.spread", label: "Bristle spread", section: .texture, range: 0.1 ... 2,
                           unit: .widths, isShown: isBristle,
                           get: {
                               if case let .bristle(_, spread) = $0.texture {
                                   Double(spread)
                               } else {
                                   1
                               }
                           },
                           apply: { b, v in
                               if case let .bristle(count, _) = b.texture {
                                   b.texture = .bristle(count: count, spread: CGFloat(v))
                               }
                           })
        ]
    }()

    // MARK: Jitter

    private static let jitter: [BrushParameter] = [
        BrushParameter(id: "jitter.size", label: "Size", section: .jitter, range: 0 ... 1, unit: .percent,
                       get: { Double($0.jitter.size) }, apply: { b, v in b.jitter.size = CGFloat(v) }),
        BrushParameter(id: "jitter.angle", label: "Angle", section: .jitter, range: 0 ... 1, unit: .percent,
                       get: { Double($0.jitter.angle) }, apply: { b, v in b.jitter.angle = CGFloat(v) }),
        BrushParameter(id: "jitter.scatter", label: "Scatter", section: .jitter, range: 0 ... 2, unit: .widths,
                       get: { Double($0.jitter.scatter) }, apply: { b, v in b.jitter.scatter = CGFloat(v) }),
        BrushParameter(id: "jitter.opacity", label: "Opacity", section: .jitter, range: 0 ... 1, unit: .percent,
                       get: { Double($0.jitter.opacity) }, apply: { b, v in b.jitter.opacity = CGFloat(v) }),
        BrushParameter(id: "jitter.seed", label: "Pattern", section: .jitter, range: 0 ... 999, unit: .integer,
                       get: { Double($0.jitter.seed) }, apply: { b, v in b.jitter.seed = UInt32(v.rounded()) })
    ]

    // MARK: Look

    private static let look: [BrushParameter] = [
        BrushParameter(id: "opacity", label: "Opacity", section: .look, range: 0.02 ... 1, unit: .percent,
                       get: { Double($0.opacity) }, apply: { b, v in b.opacity = CGFloat(v) })
    ]

    /// A response curve's amount and exponent.
    private static func curve(_ id: String, _ label: String, _ section: Section,
                              _ keyPath: WritableKeyPath<BrushDescriptor, BrushDescriptor.ResponseCurve>) -> [BrushParameter] {
        [
            BrushParameter(id: "\(id).amount", label: label, section: section, range: 0 ... 1, unit: .percent,
                           get: { Double($0[keyPath: keyPath].amount) },
                           apply: { b, v in b[keyPath: keyPath].amount = CGFloat(v) }),
            BrushParameter(id: "\(id).exponent", label: "Curve", section: section, range: 0.1 ... 5, unit: .number,
                           isShown: { $0[keyPath: keyPath].amount > 0 },
                           get: { Double($0[keyPath: keyPath].exponent) },
                           apply: { b, v in b[keyPath: keyPath].exponent = CGFloat(v) })
        ]
    }
}

extension BrushDescriptor.TipShape {
    var isRound: Bool {
        if case .round = self {
            return true
        }
        return false
    }
}

extension BrushDescriptor.Texture {
    enum Kind: Hashable {
        case none, grain, bristle
    }

    var kind: Kind {
        switch self {
        case .none: .none
        case .grain: .grain
        case .bristle: .bristle
        }
    }
}
