import NotaUI
import SwiftUI

/// Observable tool state shared by the SwiftUI shell and the UIKit canvas.
@MainActor
final class CanvasController: ObservableObject {
    struct ToolSettings: Equatable {
        var colorIndex: Int
        var width: Double
    }

    @Published private(set) var tool: Tool = .pen
    private(set) var previousTool: Tool = .pen
    @Published var eraserMode: EraserMode = .stroke
    @Published var lassoMode: LassoMode = .freeform
    @Published private(set) var hasSelection = false
    @Published var settings: [Tool: ToolSettings] = [
        .pen: ToolSettings(colorIndex: 0, width: 4),
        .pencil: ToolSettings(colorIndex: 0, width: 3),
        .highlighter: ToolSettings(colorIndex: 0, width: 22),
        .eraser: ToolSettings(colorIndex: 0, width: 30),
        .lasso: ToolSettings(colorIndex: 0, width: 4)
    ]

    // Pressure / tilt response
    @Published var minWidthRatio: Double = 0.25
    @Published var pressureGamma: Double = 0.6
    @Published var tiltEnabled = true
    @Published var hudVisible = true
    /// Simulator only: altitude fed to the fake Pencil so tilt shading can be exercised.
    @Published var simulatedAltitudeDegrees: Double = 90

    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false
    @Published private(set) var zoom: CGFloat = 1
    /// Set by a Pencil Pro squeeze; location is in canvas-view (= full-screen) coordinates.
    @Published var quickPaletteLocation: CGPoint?
    /// Space kept around the page when it's fitted to the view, on top of the safe area: room for the
    /// floating Pen Case and page bar. Set by the editor when the Pen Case moves to another edge.
    @Published var pageMargins = CanvasController.defaultPageMargins {
        didSet {
            if pageMargins != oldValue {
                canvas?.pageMarginsDidChange()
            }
        }
    }

    static let defaultPageMargins = UIEdgeInsets(top: 76, left: 24, bottom: 76, right: 24)

    weak var canvas: CanvasView?
    /// Called when the canvas is swiped sideways to turn the page. Set by the editor that owns the pages.
    var onSwipeToPage: ((PageSwipe) -> Void)?
    /// Whether there's a page to turn to in that direction (and no page turn already under way).
    var canSwipeToPage: ((PageSwipe) -> Bool)?

    func canSwipe(_ swipe: PageSwipe) -> Bool {
        canSwipeToPage?(swipe) ?? false
    }

    func swipeToPage(_ swipe: PageSwipe) {
        onSwipeToPage?(swipe)
    }

    static func widthRange(for tool: Tool) -> ClosedRange<Double> {
        switch tool {
        case .pen: 1 ... 20
        case .pencil: 1 ... 16
        case .highlighter: 8 ... 48
        case .eraser: 8 ... 100
        case .lasso: 1 ... 1
        }
    }

    /// The colour presets shown for `tool`. Highlighters get their own light, saturated set.
    static func inks(for tool: Tool) -> [NotaInk] {
        tool == .highlighter ? NotaInk.highlighterPresets : NotaInk.penPresets
    }

    /// Fine, medium and bold widths for `tool`, all inside `widthRange(for:)`.
    static func widthPresets(for tool: Tool) -> [Double] {
        switch tool {
        case .pen: [2, 4, 8]
        case .pencil: [2, 3, 6]
        case .highlighter: [14, 22, 34]
        case .eraser: [16, 30, 60]
        case .lasso: []
        }
    }

    var current: ToolSettings {
        get { settings[tool] ?? ToolSettings(colorIndex: 0, width: 4) }
        set { settings[tool] = newValue }
    }

    // MARK: Tool switching

    func select(_ newTool: Tool) {
        guard newTool != tool else { return }
        if tool == .lasso {
            canvas?.clearSelection()
        }
        previousTool = tool
        tool = newTool
    }

    /// Pencil double-tap: pen/highlighter ⇄ eraser.
    func toggleEraser() {
        if tool == .eraser {
            select(previousTool == .eraser ? .pen : previousTool)
        } else {
            select(.eraser)
        }
    }

    func switchToPrevious() {
        select(previousTool)
    }

    // MARK: Commands

    func undo() {
        canvas?.undo()
    }

    func redo() {
        canvas?.redo()
    }

    func clear() {
        canvas?.clearCanvas()
    }

    func resetZoom() {
        canvas?.resetView()
    }

    func deleteSelection() {
        canvas?.deleteSelection()
    }

    func selectionDidChange(_ has: Bool) {
        if hasSelection != has {
            hasSelection = has
        }
    }

    func documentDidChange(canUndo: Bool, canRedo: Bool) {
        if self.canUndo != canUndo {
            self.canUndo = canUndo
        }
        if self.canRedo != canRedo {
            self.canRedo = canRedo
        }
    }

    func zoomDidChange(_ scale: CGFloat) {
        let rounded = (scale * 100).rounded() / 100
        if rounded != zoom {
            zoom = rounded
        }
    }

    // MARK: Stroke template

    /// What a new stroke is built from: its ink kind, colour and brush style.
    struct StrokeTemplate {
        let kind: InkKind
        let color: RGBA
        let style: BrushStyle
    }

    /// Brush snapshot for a new stroke. `viewScale` converts the eraser's on-screen size to canvas units.
    func strokeTemplate(viewScale: CGFloat) -> StrokeTemplate {
        let s = current
        let inks = Self.inks(for: tool)
        let color = RGBA(inks[min(max(s.colorIndex, 0), inks.count - 1)])
        switch tool {
        case .pen, .highlighter, .lasso:
            let style = BrushStyle(width: CGFloat(s.width),
                                   minWidthRatio: CGFloat(minWidthRatio),
                                   pressureGamma: CGFloat(pressureGamma),
                                   opacity: tool == .highlighter ? 0.38 : 1,
                                   tiltEnabled: tiltEnabled)
            return StrokeTemplate(kind: tool == .highlighter ? .highlighter : .pen, color: color, style: style)
        case .pencil:
            let style = BrushStyle(width: CGFloat(s.width),
                                   minWidthRatio: CGFloat(minWidthRatio),
                                   pressureGamma: CGFloat(pressureGamma),
                                   opacity: 0.85,
                                   tiltEnabled: tiltEnabled)
            return StrokeTemplate(kind: .pencil, color: color, style: style)
        case .eraser:
            let style = BrushStyle(width: CGFloat(s.width) / viewScale, minWidthRatio: 1,
                                   pressureGamma: 1, opacity: 1, tiltEnabled: false)
            return StrokeTemplate(kind: .pixelEraser, color: RGBA(r: 0, g: 0, b: 0), style: style)
        }
    }

    var simulatedAltitude: CGFloat {
        CGFloat(simulatedAltitudeDegrees) * .pi / 180
    }
}
