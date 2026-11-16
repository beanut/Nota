import CoreGraphics
import Foundation
@testable import InkKit
import Testing

@Suite("Tool picker contents")
struct ToolPickerItemsTests {
    @Test func startsWithTheDesignedBar() {
        #expect(ToolPickerItems().tools == [.pen, .marker, .pencil, .eraser, .lasso, .ruler, .crayon, .fountainPen])
    }

    @Test func plusOffersOnlyToolsNotInTheBar() {
        var items = ToolPickerItems()
        #expect(items.addable == [.highlighter, .shapes, .textBox, .tape, .laser, .insert])
        items.add(.shapes)
        #expect(items.tools.last == .shapes)
        #expect(!items.addable.contains(.shapes))
    }

    @Test func addingATwiceOrDuplicatesInTheInitialiserKeepOneOfEach() {
        var items = ToolPickerItems([.pen, .pen, .lasso])
        #expect(items.tools == [.pen, .lasso])
        items.add(.lasso)
        #expect(items.tools == [.pen, .lasso])
    }

    @Test func theLastToolCantBeRemoved() {
        var items = ToolPickerItems([.pen, .lasso])
        items.remove(.lasso)
        #expect(items.tools == [.pen])
        #expect(!items.canRemove(.pen))
        items.remove(.pen)
        #expect(items.tools == [.pen])
        #expect(ToolPickerItems([]).tools == PickerTool.defaultBar)
    }

    @Test func movesOnePlaceAndStopsAtTheEnds() {
        var items = ToolPickerItems([.pen, .marker, .eraser])
        items.move(.eraser, by: -1)
        #expect(items.tools == [.pen, .eraser, .marker])
        items.move(.pen, by: -1)
        #expect(items.tools == [.pen, .eraser, .marker])
        items.move(.marker, by: 1)
        #expect(items.tools == [.pen, .eraser, .marker])
    }

    @Test func savesAndLoadsAndDropsUnknownTools() throws {
        let defaults = try #require(UserDefaults(suiteName: "ToolPickerItemsTests"))
        defaults.removePersistentDomain(forName: "ToolPickerItemsTests")
        ToolPickerItems([.highlighter, .lasso]).save(to: defaults)
        #expect(ToolPickerItems.load(from: defaults).tools == [.highlighter, .lasso])

        let future = try JSONEncoder().encode(["pen", "quill", "eraser"])
        defaults.set(future, forKey: ToolPickerItems.defaultsKey)
        #expect(ToolPickerItems.load(from: defaults).tools == [.pen, .eraser])
        defaults.removePersistentDomain(forName: "ToolPickerItemsTests")
    }
}

@Suite("Tool picker selection")
struct PickerToolSelectionTests {
    @Test func brushesPickTheirOwnSlot() {
        #expect(PickerTool.current(tool: .pen, brushID: BrushDescriptor.marker.id) == .marker)
        #expect(PickerTool.current(tool: .pen, brushID: BrushDescriptor.fountainPen.id) == .fountainPen)
        #expect(PickerTool.current(tool: .pencil, brushID: BrushDescriptor.crayon.id) == .crayon)
        #expect(PickerTool.current(tool: .pencil, brushID: BrushDescriptor.pencil.id) == .pencil)
    }

    @Test func otherBrushesLightUpThePlainToolSlot() {
        #expect(PickerTool.current(tool: .pen, brushID: BrushDescriptor.fineliner.id) == .pen)
        #expect(PickerTool.current(tool: .pen, brushID: UUID()) == .pen)
    }

    @Test func onlySlotsInTheBarAreSelected() {
        #expect(PickerTool.current(tool: .pen, brushID: BrushDescriptor.marker.id, inBar: [.pen, .eraser]) == .pen)
        #expect(PickerTool.current(tool: .highlighter, brushID: nil, inBar: [.pen]) == nil)
        #expect(PickerTool.current(tool: .shape, brushID: nil) == .shapes)
    }
}

@Suite("Tool picker layout")
struct ToolPickerLayoutTests {
    private typealias Layout = ToolPickerLayout
    /// An iPad Pro 13-inch in portrait, below the navigation row.
    private let bounds = CGSize(width: 1032, height: 1250)

    @Test func theDesignedBarIsItsFixedPartsPlusEightTools() {
        // Padding 8 + 6, Plus, colour well, undo, redo and collapse (5 × 44), two dividers, seven gaps.
        #expect(Layout.fixedLength == 264)
        #expect(Layout.rowLength(count: 8) == CGFloat(380))
        #expect(Layout.barLength(count: 8, maxLength: 2000) == CGFloat(644))
    }

    @Test func theRowScrollsOnlyOnceTheBarOutgrowsItsEdge() {
        #expect(!Layout.overflows(count: 8, maxLength: 644))
        #expect(Layout.overflows(count: 8, maxLength: 643))
        #expect(Layout.viewportLength(count: 8, maxLength: 548) == 284) // Figma's 6-slot viewport
        #expect(Layout.viewportLength(count: 8, maxLength: 100) == 44) // never less than one slot
    }

    @Test func maxLengthIsTheEdgeLessItsMargins() {
        #expect(Layout.maxLength(on: .bottom, in: bounds) == CGFloat(984))
        #expect(Layout.maxLength(on: .leading, in: bounds) == CGFloat(1202))
    }

    @Test func docksSit24PointsInFromTheirEdges() {
        #expect(Layout.center(on: .bottom, length: 644, in: bounds) == CGPoint(x: 516, y: 1250 - 50))
        #expect(Layout.center(on: .bottomLeading, length: 644, in: bounds) == CGPoint(x: 24 + 322, y: 1250 - 50))
        #expect(Layout.center(on: .trailing, length: 644, in: bounds) == CGPoint(x: 1032 - 50, y: 625))
    }

    @Test func dropsSnapToTheNearestDock() {
        #expect(Layout.nearestDock(to: CGPoint(x: 500, y: 1180), count: 8, in: bounds) == .bottom)
        #expect(Layout.nearestDock(to: CGPoint(x: 120, y: 1190), count: 8, in: bounds) == .bottomLeading)
        #expect(Layout.nearestDock(to: CGPoint(x: 960, y: 1200), count: 8, in: bounds) == .bottomTrailing)
        #expect(Layout.nearestDock(to: CGPoint(x: 30, y: 600), count: 8, in: bounds) == .leading)
        #expect(Layout.nearestDock(to: CGPoint(x: 1000, y: 500), count: 8, in: bounds) == .trailing)
        #expect(Layout.nearestDock(to: CGPoint(x: 516, y: 40), count: 8, in: bounds) == .top)
    }

    @Test func theCollapsedCircleSitsAtTheBarsEndOrInItsCorner() {
        let length: CGFloat = 644
        let bottom = Layout.center(on: .bottom, length: length, in: bounds)
        #expect(Layout.collapsedCenter(on: .bottom, length: length, in: bounds)
            == CGPoint(x: bottom.x + 296, y: bottom.y))
        #expect(Layout.collapsedCenter(on: .bottomLeading, length: length, in: bounds)
            == CGPoint(x: 24 + 26, y: bottom.y))
        #expect(Layout.collapsedCenter(on: .bottomTrailing, length: length, in: bounds)
            == CGPoint(x: 1032 - 24 - 26, y: bottom.y))
        #expect(Layout.nearestDock(to: CGPoint(x: 60, y: 1190), count: 8, in: bounds, collapsed: true) == .bottomLeading)
    }

    @Test func thicknessPreviewRunsFrom4To24Points() {
        #expect(Layout.previewDiameter(for: 0) == 4)
        #expect(Layout.previewDiameter(for: 0.4) == 12)
        #expect(Layout.previewDiameter(for: 1) == 24)
        #expect(Layout.previewDiameter(for: 2) == 24)
    }
}

@Suite("Page clipboard")
@MainActor
struct PageClipboardTests {
    @Test func pastesFreshCopiesAfterThePage() {
        let notebook = InkNotebook(pageCount: 3)
        let clipboard = PageClipboard()
        clipboard.copy([notebook.pages[0]])
        clipboard.paste(into: notebook, after: 1)
        clipboard.paste(into: notebook, after: 4)
        #expect(notebook.pageCount == 5)
        #expect(Set(notebook.pages.map(\.id)).count == 5) // every paste is a new page
    }
}
