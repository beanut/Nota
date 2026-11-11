import Foundation
import UIKit
import CoreGraphics
import Testing
@testable import InkKit

@Suite("PageSize")
struct PageSizeTests {
    @Test func defaultIsLetter() {
        #expect(PageSize.default == .letter)
        #expect(PageSize.letter.width == 612)
        #expect(PageSize.letter.height == 792)
        #expect(PageSize.letter.name == "Letter")
    }

    @Test func presetDimensionsInPoints() {
        #expect(PageSize.legal.size == CGSize(width: 612, height: 1008))
        #expect(PageSize.tabloid.size == CGSize(width: 792, height: 1224))
        #expect(abs(PageSize.a4.width - 595.28) < 0.01)
        #expect(abs(PageSize.a4.height - 841.89) < 0.01)
        #expect(PageSize.presets.allSatisfy { !$0.isLandscape && !$0.isCustom })
    }

    @Test func boundsStartAtOrigin() {
        #expect(PageSize.letter.bounds == CGRect(x: 0, y: 0, width: 612, height: 792))
    }

    @Test func customSizeIsClampedToAllowedRange() {
        let tiny = PageSize(width: 1, height: -50)
        #expect(tiny.width == PageSize.minimumDimension)
        #expect(tiny.height == PageSize.minimumDimension)

        let huge = PageSize(width: 1_000_000, height: 20_000)
        #expect(huge.width == PageSize.maximumDimension)
        #expect(huge.height == PageSize.maximumDimension)

        let ok = PageSize(width: 500, height: 700)
        #expect(ok.size == CGSize(width: 500, height: 700))
        #expect(ok.isCustom)
    }

    @Test func nonFiniteDimensionsFallBackToMinimum() {
        let size = PageSize(width: .nan, height: .infinity)
        #expect(size.width == PageSize.minimumDimension)
        #expect(size.height == PageSize.minimumDimension)
    }

    @Test func unitConstructors() {
        let inches = PageSize.inches(width: 8.5, height: 11)
        #expect(inches.hasSameDimensions(as: .letter))
        #expect(inches.isCustom)

        let mm = PageSize.millimeters(width: 210, height: 297)
        #expect(mm.hasSameDimensions(as: .a4))

        let points = PageSize(width: 300, height: 400, unit: .points)
        #expect(points.size == CGSize(width: 300, height: 400))
    }

    @Test(arguments: PageSize.Unit.allCases)
    func unitRoundTrips(unit: PageSize.Unit) {
        let value: CGFloat = 12.34
        #expect(abs(unit.fromPoints(unit.toPoints(value)) - value) < 1e-9)
        #expect(abs(unit.toPoints(unit.allowedRange.lowerBound) - PageSize.minimumDimension) < 1e-9)
        #expect(abs(unit.toPoints(unit.allowedRange.upperBound) - PageSize.maximumDimension) < 1e-9)
    }

    @Test func orientation() {
        let landscape = PageSize.letter.landscape
        #expect(landscape.size == CGSize(width: 792, height: 612))
        #expect(landscape.isLandscape)
        #expect(landscape.name == "Letter")
        #expect(landscape.portrait == .letter)
        #expect(PageSize.letter.portrait == .letter)
        #expect(landscape.landscape == landscape)

        let square = PageSize(width: 500, height: 500)
        #expect(square.landscape == square)
        #expect(square.portrait == square)
        #expect(!square.isLandscape)
    }

    @Test func displayNames() {
        #expect(PageSize.letter.displayName() == "Letter")
        #expect(PageSize.a4.landscape.displayName() == "A4 (Landscape)")
        #expect(PageSize.inches(width: 8.5, height: 11).displayName(metric: false) == "8.5 × 11 in")
        #expect(PageSize.millimeters(width: 210, height: 297).displayName(metric: true) == "210 × 297 mm")
    }

    @Test func sameDimensionsIgnoresName() {
        #expect(PageSize.inches(width: 8.5, height: 11) != .letter)
        #expect(PageSize.inches(width: 8.5, height: 11).hasSameDimensions(as: .letter))
        #expect(!PageSize.letter.hasSameDimensions(as: .a4))
    }

    @Test func codableRoundTrip() throws {
        let original = PageSize.a5.landscape
        let data = try JSONEncoder().encode(original)
        #expect(try JSONDecoder().decode(PageSize.self, from: data) == original)
    }
}

@Suite("ViewTransform.fitting")
struct ViewTransformFittingTests {
    @Test func fitsTallPageByHeightAndCentres() {
        let page = PageSize.letter.bounds
        let view = CGRect(x: 0, y: 0, width: 1000, height: 792)
        let t = ViewTransform.fitting(page: page, in: view)
        #expect(t.scale == 1)
        let shown = t.toView(page)
        #expect(shown.midX == view.midX)
        #expect(shown.minY == 0)
        #expect(shown.maxY == 792)
    }

    @Test func fitsWidePageByWidth() {
        let page = PageSize.letter.landscape.bounds   // 792 × 612
        let view = CGRect(x: 0, y: 0, width: 396, height: 1000)
        let t = ViewTransform.fitting(page: page, in: view)
        #expect(t.scale == 0.5)
        let shown = t.toView(page)
        #expect(shown.width == 396)
        #expect(shown.midY == view.midY)
    }

    @Test func respectsInsets() {
        let page = CGRect(x: 0, y: 0, width: 100, height: 100)
        let view = CGRect(x: 0, y: 0, width: 300, height: 300)
        let insets = UIEdgeInsets(top: 50, left: 50, bottom: 50, right: 50)
        let t = ViewTransform.fitting(page: page, in: view, insets: insets)
        #expect(t.scale == 2)
        #expect(t.toView(page) == CGRect(x: 50, y: 50, width: 200, height: 200))
    }

    @Test func clampsScale() {
        let page = CGRect(x: 0, y: 0, width: 10, height: 10)
        let view = CGRect(x: 0, y: 0, width: 1000, height: 1000)
        #expect(ViewTransform.fitting(page: page, in: view, scaleRange: 0.25...8).scale == 8)
        let bigPage = CGRect(x: 0, y: 0, width: 100_000, height: 100_000)
        #expect(ViewTransform.fitting(page: bigPage, in: view, scaleRange: 0.25...8).scale == 0.25)
    }

    @Test func emptyInputsGiveIdentity() {
        let page = PageSize.letter.bounds
        #expect(ViewTransform.fitting(page: page, in: .zero) == ViewTransform())
        let insets = UIEdgeInsets(top: 600, left: 0, bottom: 600, right: 0)
        #expect(ViewTransform.fitting(page: page, in: CGRect(x: 0, y: 0, width: 800, height: 1000),
                                      insets: insets) == ViewTransform())
    }

    @Test func canvasRoundTripThroughFittedTransform() {
        let t = ViewTransform.fitting(page: PageSize.a4.bounds, in: CGRect(x: 0, y: 0, width: 1032, height: 1376))
        let p = CGPoint(x: 123.5, y: 456.25)
        let back = t.toCanvas(t.toView(p))
        #expect(abs(back.x - p.x) < 1e-9 && abs(back.y - p.y) < 1e-9)
    }
}

@Suite("Zoom limits")
struct ZoomLimitTests {
    @Test func zoomOutStopsAtWholePage() {
        #expect(ViewTransform.zoomRange(fitScale: 1.4).lowerBound == 1.4)
        #expect(ViewTransform.zoomRange(fitScale: 0.05).lowerBound == 0.05)
    }

    @Test func zoomInStopsAtSixTimesFit() {
        #expect(ViewTransform.zoomRange(fitScale: 1.5).upperBound == 9)
        #expect(ViewTransform.zoomRange(fitScale: 20).upperBound == 120)
    }

    @Test func largePagesCanStillZoomToSixTimesActualSize() {
        // A 200 in page fits at a tiny scale; six times that would still be unreadable.
        #expect(ViewTransform.zoomRange(fitScale: 0.07).upperBound == 6)
    }

    @Test func badFitScaleFallsBack() {
        #expect(ViewTransform.zoomRange(fitScale: 0) == 1...6)
        #expect(ViewTransform.zoomRange(fitScale: .infinity) == 1...6)
    }

    @Test func fittingNoLongerClampsVeryLargeOrSmallPages() {
        let view = CGRect(x: 0, y: 0, width: 1000, height: 1000)
        let huge = CGRect(x: 0, y: 0, width: 14_400, height: 14_400)   // 200 in square
        let scale = ViewTransform.fitting(page: huge, in: view,
                                          scaleRange: .leastNonzeroMagnitude...(.greatestFiniteMagnitude)).scale
        #expect(abs(scale - 1000 / 14_400) < 1e-9)
    }

    @Test func recentringOnlyNearTheZoomOutLimit() {
        let fit: CGFloat = 2
        // Zooming in, or zooming out well above the band, leaves the page where the pinch put it.
        #expect(ViewTransform.recentringAmount(from: 2.2, to: 2.4, fitScale: fit) == 0)
        #expect(ViewTransform.recentringAmount(from: 6, to: 4, fitScale: fit) == 0)
        // Halfway down the band closes half the gap; reaching the limit closes all of it.
        #expect(ViewTransform.recentringAmount(from: 2.5, to: 2.25, fitScale: fit) == 0.5)
        #expect(ViewTransform.recentringAmount(from: 2.25, to: 2, fitScale: fit) == 1)
        #expect(ViewTransform.recentringAmount(from: 2, to: 2, fitScale: fit) == 1)
    }
}

@Suite("Page swipes")
struct PageSwipeTests {
    let width: CGFloat = 1000

    @Test func longSidewaysDragsTurnThePage() {
        #expect(PageSwipe.detect(translation: CGPoint(x: -300, y: 20), velocity: .zero, viewWidth: width) == .next)
        #expect(PageSwipe.detect(translation: CGPoint(x: 300, y: -20), velocity: .zero, viewWidth: width) == .previous)
    }

    @Test func quickFlicksTurnThePage() {
        #expect(PageSwipe.detect(translation: CGPoint(x: -60, y: 5), velocity: CGPoint(x: -900, y: 0), viewWidth: width) == .next)
        #expect(PageSwipe.detect(translation: CGPoint(x: 60, y: 5), velocity: CGPoint(x: 900, y: 0), viewWidth: width) == .previous)
    }

    @Test func shortSlowDragsDoNothing() {
        #expect(PageSwipe.detect(translation: CGPoint(x: -150, y: 0), velocity: CGPoint(x: -200, y: 0), viewWidth: width) == nil)
        #expect(PageSwipe.detect(translation: CGPoint(x: -20, y: 0), velocity: CGPoint(x: -2000, y: 0), viewWidth: width) == nil)
    }

    @Test func mostlyVerticalDragsDoNothing() {
        #expect(PageSwipe.detect(translation: CGPoint(x: -300, y: 250), velocity: .zero, viewWidth: width) == nil)
    }

    @Test func flickBackAgainstTheDragDoesNothing() {
        // Dragged left, then flicked back right before lifting: the user changed their mind.
        #expect(PageSwipe.detect(translation: CGPoint(x: -100, y: 0), velocity: CGPoint(x: 900, y: 0), viewWidth: width) == nil)
    }

    @Test func emptyViewDoesNothing() {
        #expect(PageSwipe.detect(translation: CGPoint(x: -300, y: 0), velocity: .zero, viewWidth: 0) == nil)
    }
}
