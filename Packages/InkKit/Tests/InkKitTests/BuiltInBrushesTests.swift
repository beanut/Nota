import CoreGraphics
import Foundation
@testable import InkKit
import Testing

@Suite("Built-in brushes")
struct BuiltInBrushesTests {
    // MARK: The set

    @Test func everyFamilyIsBundledOnceWithFixedIDs() {
        let families = BrushDescriptor.pens + BrushDescriptor.pencils + BrushDescriptor.highlighters
        #expect(BrushDescriptor.bundled.count == families.count + 1)
        #expect(Set(families.map(\.id)).count == families.count)
        #expect(Set(families.map(\.name)).count == families.count)
        // The original tools keep their ids, so strokes drawn before the set existed still read as built in.
        #expect(BrushDescriptor.pen.id.uuidString == "6E6F7461-0000-4000-8000-000000000001")
        #expect(BrushDescriptor.pencil.id.uuidString == "6E6F7461-0000-4000-8000-000000000002")
        #expect(BrushDescriptor.highlighter.id.uuidString == "6E6F7461-0000-4000-8000-000000000003")
        #expect(BrushDescriptor.pixelEraser.id.uuidString == "6E6F7461-0000-4000-8000-000000000004")
        for brush in BrushDescriptor.bundled {
            #expect(BrushDescriptor.bundled(id: brush.id) == brush)
        }
        #expect(BrushDescriptor.bundled(id: UUID()) == nil)
    }

    @Test func familiesMatchWhatTheEraserTargets() {
        #expect(BrushDescriptor.pencils.allSatisfy { EraserTarget.pencil.erases($0) })
        #expect(BrushDescriptor.highlighters.allSatisfy { EraserTarget.highlighter.erases($0) })
        #expect(BrushDescriptor.pens.allSatisfy { !EraserTarget.pencil.erases($0) && !EraserTarget.highlighter.erases($0) })
    }

    /// "Visibly distinct": no two brushes in a family draw the same sample stroke.
    @MainActor
    @Test func brushesInAFamilyDrawDifferently() throws {
        for family in [BrushDescriptor.pens, BrushDescriptor.pencils, BrushDescriptor.highlighters] {
            let images = try family.map { brush in
                try #require(BrushPreview.image(of: brush, color: RGBA(r: 0.1, g: 0.2, b: 0.5), scale: 2))
            }
            for i in images.indices {
                for j in images.indices where j > i {
                    let diff = try #require(compare(images[i], images[j]))
                    #expect(diff.differingPixels > 200, "\(family[i].name) vs \(family[j].name)")
                }
            }
        }
    }

    // MARK: Pressure & Tilt settings

    @Test func theBallpointTakesTheSettingsAsTheyAre() {
        for (ratio, gamma, tilt) in [(0.25, 0.6, true), (0.02, 2.5, false), (1, 0.3, true), (0.6, 1, true)] {
            let personal = BrushDescriptor.pen.personalized(width: 7, minimumWidthRatio: ratio,
                                                            pressureExponent: gamma, tilt: tilt)
            var expected = BrushDescriptor.pen.sized(7, minimumRatio: ratio)
            expected.pressure.exponent = gamma
            expected.tilt.enabled = tilt
            #expect(personal == expected, "ratio \(ratio), γ \(gamma), tilt \(tilt)")
        }
    }

    @Test func neutralSettingsKeepEachBrushsCharacter() {
        for brush in BrushDescriptor.bundled where !brush.erases {
            let personal = brush.personalized(width: brush.maxWidth,
                                              minimumWidthRatio: BrushDescriptor.neutralMinimumWidthRatio,
                                              pressureExponent: BrushDescriptor.neutralPressureExponent, tilt: true)
            #expect(abs(personal.size.lowerBound - brush.size.lowerBound) < 1e-9, "\(brush.name)")
            #expect(personal.size.upperBound == brush.size.upperBound)
            #expect(abs(personal.pressure.exponent - brush.pressure.exponent) < 1e-9, "\(brush.name)")
            #expect(personal.tilt == brush.tilt && personal.tip == brush.tip && personal.taper == brush.taper)
        }
    }

    @Test func settingsMoveEveryBrushTheSameWay() {
        let brush = BrushDescriptor.brushPen
        let ownRatio = brush.size.lowerBound / brush.maxWidth
        func ratio(_ setting: CGFloat) -> CGFloat {
            let b = brush.personalized(width: 10, minimumWidthRatio: setting, pressureExponent: 0.6, tilt: true)
            return b.size.lowerBound / b.maxWidth
        }
        #expect(abs(ratio(1) - 1) < 1e-9) // constant width
        #expect(ratio(0.02) < ownRatio && ratio(0.5) > ownRatio)
        #expect(ratio(0.02) >= 0)
        let firmer = brush.personalized(width: 10, minimumWidthRatio: 0.25, pressureExponent: 1.2, tilt: true)
        #expect(abs(firmer.pressure.exponent - brush.pressure.exponent * 2) < 1e-9)
        let soft = BrushDescriptor.softPencil.personalized(width: 5, minimumWidthRatio: 0.25,
                                                           pressureExponent: 0.6, tilt: false)
        #expect(!soft.tilt.enabled)
        // A brush with no tilt shading doesn't gain any.
        #expect(!BrushDescriptor.fineliner.personalized(width: 3, minimumWidthRatio: 0.25, pressureExponent: 0.6,
                                                        tilt: true).tilt.enabled)
    }

    @Test func personalizedRejectsNonsense() {
        let b = BrushDescriptor.fountainPen.personalized(width: .nan, minimumWidthRatio: .infinity,
                                                         pressureExponent: -1, tilt: true)
        #expect(b.clamped() == b)
        #expect(b.pressure == BrushDescriptor.fountainPen.pressure)
    }

    // MARK: Picking a brush

    @MainActor
    @Test func eachToolRemembersItsBrushAndEachBrushItsWidth() throws {
        let suite = "BuiltInBrushesTests.\(UUID().uuidString)"
        let store = try #require(UserDefaults(suiteName: suite))
        defer { store.removePersistentDomain(forName: suite) }
        let c = CanvasController(settingsStore: store)
        #expect(c.brush(for: .pen) == .pen && c.brush(for: .pencil) == .pencil)
        #expect(c.brush(for: .highlighter) == .highlighter && c.brush(for: .eraser) == .pixelEraser)

        c.selectBrush(.fountainPen, for: .pen)
        #expect(c.brush(for: .pen) == .fountainPen)
        #expect(c.settings[.pen]?.width == Double(BrushDescriptor.fountainPen.maxWidth)) // its default width
        c.settings[.pen]?.width = 9
        c.selectBrush(.pen, for: .pen)
        #expect(c.settings[.pen]?.width == 4) // the ballpoint's width from before
        c.selectBrush(.fountainPen, for: .pen)
        #expect(c.settings[.pen]?.width == 9)

        // A brush from another family is refused.
        c.selectBrush(.softPencil, for: .pen)
        #expect(c.brush(for: .pen) == .fountainPen)

        // New strokes use the chosen brush, with the settings applied.
        c.select(.pen)
        c.minWidthRatio = 0.25
        c.pressureGamma = 0.6
        let template = c.strokeTemplate(viewScale: 1)
        #expect(template.brush.id == BrushDescriptor.fountainPen.id && template.brush.maxWidth == 9)
        #expect(template.brush.tip == BrushDescriptor.fountainPen.tip)
        c.select(.pencil)
        c.selectBrush(.softPencil, for: .pencil)
        #expect(c.strokeTemplate(viewScale: 1).brush.texture == BrushDescriptor.softPencil.texture)
    }
}
