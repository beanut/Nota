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
    /// Which ink the eraser removes. Only standard and stroke erasing can be limited (`EraserMode.canTarget`).
    @Published var eraserTarget: EraserTarget = .all
    /// Goes back to the previous tool when an eraser stroke ends.
    @Published var switchBackAfterErasing = false
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
    /// Set while Record Pencil Input is on; the canvas feeds it every ink event (see `InkInputRecording`).
    private(set) var inputRecorder: InputRecorder?
    @Published private(set) var isRecordingInput = false
    /// The last finished recording, written to a temporary file so the More menu can share it.
    @Published private(set) var lastRecordingURL: URL?
    /// Simulator only: altitude fed to the fake Pencil so tilt shading can be exercised.
    @Published var simulatedAltitudeDegrees: Double = 90

    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false
    @Published private(set) var zoom: CGFloat = 1
    /// Set by a Pencil double-tap or squeeze; location is in canvas-view (= full-screen) coordinates.
    @Published var quickPaletteLocation: CGPoint?
    /// Apple Pencil gestures, finger drawing, palm rejection and handedness. Saved to `UserDefaults`,
    /// so every editor shares them; a change made in one window reaches the others when they next open.
    @Published var pencilSettings: PencilSettings {
        didSet {
            guard pencilSettings != oldValue else { return }
            pencilSettings.save(to: settingsStore)
            canvas?.pencilSettingsDidChange()
        }
    }

    private let settingsStore: UserDefaults

    init(settingsStore: UserDefaults = .standard) {
        self.settingsStore = settingsStore
        pencilSettings = PencilSettings.load(from: settingsStore)
    }

    /// Space kept around the page when it's fitted to the view, on top of the safe area: room for the
    /// floating page bar at the bottom. The Pen Case lives in the navigation bar, inside the safe area.
    @Published var pageMargins = CanvasController.defaultPageMargins {
        didSet {
            if pageMargins != oldValue {
                canvas?.pageMarginsDidChange()
            }
        }
    }

    /// Top: a 24 pt gap under the navigation bar. Bottom: the 44 pt page bar, its 8 pt inset and a gap.
    static let defaultPageMargins = UIEdgeInsets(top: 24, left: 24, bottom: 76, right: 24)

    // Zoom window

    /// Shows the zoom window: a magnified writing panel at the bottom of the canvas for the box on the page.
    @Published var zoomWindowVisible = false {
        didSet {
            if zoomWindowVisible != oldValue {
                canvas?.zoomWindowVisibilityDidChange()
            }
        }
    }

    /// The zoom window's controls, in canvas-view (= full-screen) coordinates, while it's shown.
    @Published private(set) var zoomControlsFrame: CGRect?
    /// Whether the zoom box can move back (it's not at the start of the first line).
    @Published private(set) var zoomCanGoBack = false
    /// The zoom box in page points, kept so the next page opens with the box where it was.
    var zoomBox: CGRect?
    /// The lines on a page, for the zoom window to follow. Set by the editor; nil uses the page template's lines.
    var writingLines: ((CanvasDocument) -> WritingLines?)?

    weak var canvas: CanvasView?
    /// The editor's theme; its ink presets colour new strokes. Set by the canvas from the environment.
    var theme = InkTheme.standard
    /// Called when the canvas is swiped sideways to turn the page. Set by the editor that owns the pages.
    var onSwipeToPage: ((PageSwipe) -> Void)?
    /// Whether there's a page to turn to in that direction (and no page turn already under way).
    var canSwipeToPage: ((PageSwipe) -> Bool)?

    /// Starts or stops recording Pencil input. Stopping writes the strokes recorded so far (if any) to
    /// a temporary `.inkrec.json` file, offered by the More menu for the benchmarks' fixtures.
    func setRecordingInput(_ on: Bool) {
        guard on != isRecordingInput else { return }
        if on {
            inputRecorder = InputRecorder()
        } else if let recording = inputRecorder?.recording {
            inputRecorder = nil
            if !recording.strokes.isEmpty, let data = try? recording.encoded() {
                let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent("pencil-\(stamp).inkrec.json")
                if (try? data.write(to: url)) != nil {
                    lastRecordingURL = url
                }
            }
        }
        isRecordingInput = on
    }

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

    /// Runs a resolved double-tap or squeeze action. `location` is where to show the palette, in
    /// canvas-view coordinates; showing it again while it's up hides it.
    func perform(_ action: PencilSettings.Action, at location: CGPoint) {
        switch action {
        case .eraser: toggleEraser()
        case .previousTool: switchToPrevious()
        case .palette: quickPaletteLocation = quickPaletteLocation == nil ? location : nil
        case .system, .off: break
        }
    }

    /// The ink the eraser removes in the current mode.
    var effectiveEraserTarget: EraserTarget {
        eraserMode.canTarget ? eraserTarget : .all
    }

    /// Called by the canvas when an eraser stroke ends; goes back to the previous tool if that's on.
    func eraserStrokeDidEnd() {
        guard switchBackAfterErasing, tool == .eraser, previousTool != .eraser else { return }
        switchToPrevious()
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

    func zoomWindowBack() {
        canvas?.moveZoomWindow(.back)
    }

    func zoomWindowAdvance() {
        canvas?.moveZoomWindow(.advance)
    }

    func zoomWindowNewLine() {
        canvas?.moveZoomWindow(.newLine)
    }

    func zoomWindowDidChange(controlsFrame: CGRect?, canGoBack: Bool) {
        if zoomControlsFrame != controlsFrame {
            zoomControlsFrame = controlsFrame
        }
        if zoomCanGoBack != canGoBack {
            zoomCanGoBack = canGoBack
        }
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

    /// What a new stroke is built from: its colour and brush.
    struct StrokeTemplate {
        let color: RGBA
        let brush: BrushDescriptor
    }

    /// The bundled brush each tool draws with, before the width and pressure settings are applied.
    static func baseBrush(for tool: Tool) -> BrushDescriptor {
        switch tool {
        case .pen, .lasso: .pen
        case .pencil: .pencil
        case .highlighter: .highlighter
        case .eraser: .pixelEraser
        }
    }

    /// Brush snapshot for a new stroke. `viewScale` converts the eraser's on-screen size to canvas units.
    func strokeTemplate(viewScale: CGFloat) -> StrokeTemplate {
        let s = current
        let inks = theme.inks(for: tool)
        let color = RGBA(inks[min(max(s.colorIndex, 0), inks.count - 1)])
        var brush = Self.baseBrush(for: tool)
        if tool == .eraser {
            return StrokeTemplate(color: RGBA(r: 0, g: 0, b: 0),
                                  brush: brush.sized(CGFloat(s.width) / viewScale, minimumRatio: 1))
        }
        // Pressure & Tilt settings apply to every ink brush.
        brush = brush.sized(CGFloat(s.width), minimumRatio: CGFloat(minWidthRatio))
        brush.pressure.exponent = CGFloat(pressureGamma)
        brush.tilt.enabled = tiltEnabled
        return StrokeTemplate(color: color, brush: brush)
    }

    var simulatedAltitude: CGFloat {
        CGFloat(simulatedAltitudeDegrees) * .pi / 180
    }
}
