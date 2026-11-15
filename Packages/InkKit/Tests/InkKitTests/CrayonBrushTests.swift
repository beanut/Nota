import CoreGraphics
import Foundation
@testable import InkKit
import Testing

@Suite("Crayon brush")
struct CrayonBrushTests {
    @Test func itIsInThePencilFamilyWithAFixedID() {
        #expect(BrushDescriptor.pencils.contains(.crayon))
        #expect(BrushDescriptor.bundled(id: BrushDescriptor.crayon.id) == .crayon)
        #expect(BrushDescriptor.crayon.id.uuidString == "6E6F7461-0000-4000-8000-00000000000D")
        #expect(BrushDescriptor.crayon.clamped() == .crayon)
    }

    @Test func itIsGrainedWaxThatRespondsToPressureAndTilt() {
        let crayon = BrushDescriptor.crayon
        guard case let .grain(scale, contrast, _) = crayon.texture else {
            Issue.record("the crayon should be a grain-textured brush")
            return
        }
        // A crisper speckle than the soft pencil's, with the paper showing through but more opaque.
        guard case let .grain(softScale, softContrast, _) = BrushDescriptor.softPencil.texture else { return }
        #expect(scale < softScale)
        #expect(contrast > softContrast && contrast < 1.0 + 1e-9)
        #expect(crayon.opacity > 0.85 && crayon.opacity < 1)
        #expect(crayon.pressure.isActive && crayon.pressureOpacity.isActive && crayon.tilt.enabled)
        #expect(crayon.size.lowerBound < crayon.size.upperBound)
    }

    @Test func itSurvivesTheNotePackageFormat() throws {
        let data = try JSONEncoder().encode(BrushDescriptor.crayon)
        #expect(try JSONDecoder().decode(BrushDescriptor.self, from: data) == .crayon)
        // A stroke holds a snapshot of its brush, so an older build, which has no crayon of its own, still
        // draws it: the descriptor only uses a grain texture and parameters every build knows.
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["texture"] != nil)
    }

    @Test func theEraserAndLassoTreatItLikePencilInk() {
        #expect(EraserTarget.pencil.erases(.crayon))
        #expect(EraserTarget.all.erases(.crayon))
        #expect(!EraserTarget.highlighter.erases(.crayon))
    }

    @Test func settingsAdjustItWithoutLosingItsCharacter() {
        let personal = BrushDescriptor.crayon.personalized(width: 6, minimumWidthRatio: 0.25,
                                                           pressureExponent: 0.6, tilt: true)
        #expect(personal.texture == BrushDescriptor.crayon.texture)
        #expect(personal.opacity == BrushDescriptor.crayon.opacity)
        #expect(personal.maxWidth == 6)
    }

    @MainActor
    @Test func theSameInkDrawsTheSamePixelsEveryTime() throws {
        let stroke = brushStroke(.pencil, width: 6, tilt: true, wave: 0).with(.crayon)
        func render() throws -> CGImage {
            let doc = CanvasDocument(pageSize: PageSize(width: 300, height: 160))
            doc.add(stroke)
            return try #require(PageRenderer.image(of: doc.snapshot(), pixelWidth: 600) { ctx, size in
                ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
                ctx.fill(CGRect(origin: .zero, size: size))
            })
        }
        let diff = try #require(compare(render(), render()))
        #expect(diff.differingPixels == 0)
    }
}
