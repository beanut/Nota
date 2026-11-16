import Combine
import SwiftUI

/// Observable tool state shared by the SwiftUI shell and the UIKit canvas.
@MainActor
final class CanvasController: ObservableObject {
    struct ToolSettings: Equatable {
        /// The colour the tool draws in; nil is the first quick colour (`quickColors(for:)`).
        var color: PenColor?
        var width: Double
        /// The brush the tool draws with: built in, custom or a saved pen's; nil is the tool's default.
        var brush: BrushDescriptor?
    }

    @Published private(set) var tool: Tool = .pen
    private(set) var previousTool: Tool = .pen
    @Published var eraserMode: EraserMode = .stroke
    /// Which ink the eraser removes. Only standard and stroke erasing can be limited (`EraserMode.canTarget`).
    @Published var eraserTarget: EraserTarget = .all
    /// Goes back to the previous tool when an eraser stroke ends.
    @Published var switchBackAfterErasing = false
    @Published var lassoMode: LassoMode = .freeform
    /// What the lasso picks up: ink, objects or both. Never empty.
    @Published var lassoFilter: LassoFilter = .all
    @Published private(set) var hasSelection = false
    /// Whether the pasteboard holds a lasso selection to paste (from any page of any note).
    @Published private(set) var canPaste = false
    /// Where Cut, Copy and Paste go: the system pasteboard, or a private one in tests.
    let pasteboard: UIPasteboard
    private var pasteboardObservers: [AnyCancellable] = []
    /// The app's own actions in the selection's menu, after InkKit's (see `SelectionAction`).
    var selectionActions: [SelectionAction] = []
    @Published var settings: [Tool: ToolSettings] = [
        .pen: ToolSettings(width: 4),
        .pencil: ToolSettings(width: 3),
        .highlighter: ToolSettings(width: 22),
        .eraser: ToolSettings(width: 30),
        .lasso: ToolSettings(width: 4),
        .shape: ToolSettings(width: 3),
        .text: ToolSettings(width: 17),
        .tape: ToolSettings(width: Double(TapeObject.defaultWidth)),
        .laser: ToolSettings(width: 4)
    ]

    /// The last width used with each brush, so switching brushes in a tool brings back each one's width.
    private var brushWidths: [UUID: Double] = [:]

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
            continuousHost?.pencilSettingsDidChange()
        }
    }

    /// Pages one at a time with sideways swipes, or one continuous vertical column. Saved to
    /// `UserDefaults` like `pencilSettings`, so it's the same in every editor.
    @Published var pageLayout: PageLayoutMode {
        didSet {
            guard pageLayout != oldValue else { return }
            pageLayout.save(to: settingsStore)
            if pageLayout == .continuous {
                zoomWindowVisible = false // the zoom window works on one fitted page
            }
        }
    }

    /// False in a single-page editor, which has nothing to scroll through.
    @Published var allowsContinuousLayout = true

    private let settingsStore: UserDefaults
    /// Saved pens, quick sizes and colours, custom brushes, palettes and recent colours, shared by every
    /// editor and saved across launches.
    let penTray: PenTrayStore
    private var penTrayObservation: AnyCancellable?

    // Pen tray, colour picker and brush editor

    /// The tool whose brush the brush editor is editing, while it's open.
    @Published var brushEditorTool: Tool?
    /// The crop bar's state while a picture is being cropped (see `ImageCropView`).
    @Published private(set) var imageCrop: ImageCropState?
    /// Whether the pasteboard holds pictures from another app to paste.
    @Published private(set) var canPasteImages = false
    /// The sticker collection the picker shows and Save as Sticker adds to.
    let stickers: StickerStore

    // Tape, ruler, laser and presenting

    /// What new tape is printed with; its colour is the Pen Case's and its width the tool's.
    @Published var tapePattern: TapeObject.Pattern = .plain
    /// Whether the laser leaves a fading trail or is a dot that follows the touch.
    @Published var laserMode: LaserTrail.Mode = .trail
    /// Shows the ruler over the canvas (`RulerView`). Not saved: it's for this editor while it's open.
    @Published var rulerVisible = false {
        didSet {
            if rulerVisible != oldValue {
                canvas?.updateRuler()
                continuousHost?.updateRuler()
            }
        }
    }

    /// A straight ruler, or a protractor.
    @Published var rulerMode: Ruler.Mode = .ruler {
        didSet { rulerView?.setMode(rulerMode) }
    }

    /// Where the ruler is, kept as it's moved so it stays put across pages and layouts. Nil until it's first shown.
    var ruler: Ruler?
    /// The ruler on screen, while it's shown.
    weak var rulerView: RulerView?
    /// Where the laser goes to be shown on an external display, and which page that display shows.
    let presentation: InkPresentation

    /// While set, the next touch on the canvas picks a colour from the page (see `EyedropperOverlay`).
    @Published var eyedropper: EyedropperRequest?

    struct EyedropperRequest: Equatable {
        let tool: Tool
        /// The quick colour to replace with the picked colour, if the picker was editing one.
        let quickColorIndex: Int?
    }

    /// `penTray` defaults to `PenTrayStore.shared`, `stickers` to `StickerStore.shared`, `pasteboard` to
    /// the general pasteboard and `presentation` to `InkPresentation.shared`.
    init(settingsStore: UserDefaults = .standard, penTray: PenTrayStore? = nil, stickers: StickerStore? = nil,
         pasteboard: UIPasteboard = .general, presentation: InkPresentation? = nil) {
        self.settingsStore = settingsStore
        self.presentation = presentation ?? .shared
        self.pasteboard = pasteboard
        self.stickers = stickers ?? .shared
        let penTray = penTray ?? .shared
        self.penTray = penTray
        pencilSettings = PencilSettings.load(from: settingsStore)
        pageLayout = PageLayoutMode.load(from: settingsStore)
        // Views reading quick colours, sizes and pens through the controller redraw when the tray changes.
        penTrayObservation = penTray.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        // Another app (or another of our windows) may have copied something since.
        let center = NotificationCenter.default
        pasteboardObservers = [
            center.publisher(for: UIPasteboard.changedNotification, object: pasteboard),
            center.publisher(for: UIApplication.didBecomeActiveNotification)
        ].map { $0.receive(on: RunLoop.main).sink { [weak self] _ in self?.refreshCanPaste() } }
        refreshCanPaste()
    }

    /// Checks whether the pasteboard holds a selection, without reading it (so no paste prompt).
    func refreshCanPaste() {
        let images = pasteboard.hasImages
        let has = images || pasteboard.contains(pasteboardTypes: [SelectionClip.pasteboardType])
        if canPaste != has {
            canPaste = has
        }
        if canPasteImages != images {
            canPasteImages = images
        }
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

    /// The page the tools, undo and selection act on. In continuous scrolling, the page being worked on.
    weak var canvas: CanvasView?
    /// The continuous-scrolling view, while the editor shows one.
    weak var continuousHost: ContinuousCanvasView?
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
        case .lasso, .text, .laser: 1 ... 1
        case .shape: 1 ... 20
        case .tape: 8 ... 60
        }
    }

    /// Fine, medium and bold widths for `tool`, all inside `widthRange(for:)`.
    static func widthPresets(for tool: Tool) -> [Double] {
        switch tool {
        case .pen: [2, 4, 8]
        case .pencil: [2, 3, 6]
        case .highlighter: [14, 22, 34]
        case .eraser: [16, 30, 60]
        case .lasso, .text, .laser: []
        case .shape: [2, 3, 6]
        case .tape: [12, 20, 32]
        }
    }

    var current: ToolSettings {
        get { settings[tool] ?? ToolSettings(width: 4) }
        set { settings[tool] = newValue }
    }

    // MARK: Tool switching

    func select(_ newTool: Tool) {
        guard newTool != tool else { return }
        canvas?.finishImageCrop(commit: true)
        if tool == .lasso {
            canvas?.clearSelection()
        }
        canvas?.endEditingText()
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
        canvas?.finishImageCrop(commit: false)
        canvas?.undo()
    }

    func redo() {
        canvas?.finishImageCrop(commit: false)
        canvas?.redo()
    }

    func clear() {
        canvas?.clearCanvas()
    }

    func resetZoom() {
        if let continuousHost {
            continuousHost.resetZoom()
        } else {
            canvas?.resetView()
        }
    }

    /// A page in continuous scrolling is about to take ink: it becomes the page being worked on.
    func embeddedCanvasWillInk(_ canvas: CanvasView) {
        continuousHost?.activate(canvas)
    }

    /// Ink (not an eraser stroke) was committed on `document`; `bounds` are its canvas-space bounds.
    func inkDidCommit(on document: CanvasDocument, bounds: CGRect) {
        continuousHost?.inkDidCommit(on: document, bounds: bounds)
    }

    func deleteSelection() {
        canvas?.deleteSelection()
    }

    func cutSelection() {
        canvas?.cutSelection()
    }

    func copySelection() {
        canvas?.copySelection()
    }

    /// Pastes the pasteboard's selection onto the current page and selects it.
    func paste() {
        canvas?.paste()
    }

    func duplicateSelection() {
        canvas?.duplicateSelection()
    }

    /// Recolours the selection (one undo step).
    func recolorSelection(_ color: PenColor) {
        canvas?.recolorSelection(color)
    }

    /// Turns `kind` on or off in the lasso's filter. The last kind left on stays on.
    func setLassoFilter(_ kind: LassoFilter, included: Bool) {
        var filter = lassoFilter
        if included {
            filter.insert(kind)
        } else {
            filter.remove(kind)
        }
        if !filter.isEmpty {
            lassoFilter = filter
        }
    }

    /// Adds a placeholder object (the object layer's test object) to the page in the pen's colour and
    /// selects it with the lasso, ready to move, resize or rotate.
    func insertPlaceholderObject() {
        let color = color(for: .pen)
        select(.lasso)
        canvas?.insertPlaceholderObject(color: color)
    }

    /// Reveals every tape on the current page, or hides it again (one undo step).
    func setAllTape(revealed: Bool) {
        canvas?.setAllTape(revealed: revealed)
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

    /// The page's zoom changed. `zoom` is published once it has stopped changing: a pinch changes it every
    /// frame, and publishing each one would have SwiftUI work out the whole editor's chrome again every
    /// frame of the pinch, for a number that's only shown in the More menu.
    func zoomDidChange(_ scale: CGFloat) {
        rulerView?.pageScaleDidChange()
        let rounded = (scale * 100).rounded() / 100
        zoomPublication?.cancel()
        zoomPublication = nil
        guard rounded != zoom else { return }
        let publication = DispatchWorkItem { [weak self] in
            guard let self else { return }
            zoomPublication = nil
            if rounded != zoom {
                zoom = rounded
            }
        }
        zoomPublication = publication
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.zoomPublicationDelay, execute: publication)
    }

    /// How long the zoom must hold still before `zoom` is published.
    static let zoomPublicationDelay: TimeInterval = 0.15
    private var zoomPublication: DispatchWorkItem?

    // MARK: Stroke template

    /// What a new stroke is built from: its colour and brush.
    struct StrokeTemplate {
        let color: RGBA
        let brush: BrushDescriptor
    }

    /// The bundled brush each tool draws with by default, before the width and pressure settings are applied.
    static func baseBrush(for tool: Tool) -> BrushDescriptor {
        switch tool {
        case .pen, .lasso, .shape, .text, .tape, .laser: .pen
        case .pencil: .pencil
        case .highlighter: .highlighter
        case .eraser: .pixelEraser
        }
    }

    /// The built-in brushes `tool` can draw with, in picker order; empty for tools with no choice.
    static func brushes(for tool: Tool) -> [BrushDescriptor] {
        switch tool {
        case .pen: BrushDescriptor.pens
        case .pencil: BrushDescriptor.pencils
        case .highlighter: BrushDescriptor.highlighters
        case .shape, .text, .tape, .eraser, .lasso, .laser: []
        }
    }

    /// The brushes the brush picker offers for `tool`: the built-in ones, then the user's own.
    func availableBrushes(for tool: Tool) -> [BrushDescriptor] {
        guard let kind = tool.penKind else { return [] }
        return Self.brushes(for: tool) + penTray.tray[presets: kind].brushes
    }

    /// Whether `brush` is one the user made (it can be edited in place and deleted).
    func isCustomBrush(_ brush: BrushDescriptor, for tool: Tool) -> Bool {
        guard let kind = tool.penKind else { return false }
        return penTray.tray[presets: kind].brushes.contains { $0.id == brush.id }
    }

    /// The brush `tool` currently draws with, before the width and pressure settings are applied.
    func brush(for tool: Tool) -> BrushDescriptor {
        settings[tool]?.brush ?? Self.baseBrush(for: tool)
    }

    /// Makes `tool` draw with `brush` (one of `availableBrushes(for:)`), at the width last used with it
    /// or, the first time, its own default width.
    func selectBrush(_ brush: BrushDescriptor, for tool: Tool) {
        guard availableBrushes(for: tool).contains(where: { $0.id == brush.id }) else { return }
        setBrush(brush, for: tool, width: nil)
    }

    /// Makes `tool` draw with `brush` at `width`, or at the width last used with the brush.
    private func setBrush(_ brush: BrushDescriptor, for tool: Tool, width: Double?) {
        var s = settings[tool] ?? ToolSettings(width: Double(brush.maxWidth))
        let current = self.brush(for: tool)
        guard current != brush || width != nil else { return }
        brushWidths[current.id] = s.width
        s.width = clampedWidth(width ?? brushWidths[brush.id] ?? Double(brush.maxWidth), for: tool)
        s.brush = brush
        settings[tool] = s
    }

    private func clampedWidth(_ width: Double, for tool: Tool) -> Double {
        let range = Self.widthRange(for: tool)
        return min(max(width.isFinite ? width : range.lowerBound, range.lowerBound), range.upperBound)
    }

    // MARK: Quick sizes and colours

    /// The three quick widths for `tool`: the user's, or the defaults (`widthPresets(for:)`).
    func quickSizes(for tool: Tool) -> [Double] {
        let defaults = Self.widthPresets(for: tool)
        guard let kind = tool.penKind, let sizes = penTray.tray[presets: kind].sizes,
              sizes.count == defaults.count else { return defaults }
        return sizes.map { clampedWidth($0, for: tool) }
    }

    /// Makes quick size `index` of `tool` its current width.
    func setQuickSize(at index: Int, for tool: Tool) {
        guard let kind = tool.penKind, let width = settings[tool]?.width else { return }
        penTray.update { $0.setQuickSize(width, at: index, for: kind, defaults: Self.widthPresets(for: tool)) }
    }

    func resetQuickSizes(for tool: Tool) {
        guard let kind = tool.penKind else { return }
        penTray.update { $0.resetQuickSizes(for: kind) }
    }

    /// The theme's inks for `tool`, as pen colours.
    func themeColors(for tool: Tool) -> [PenColor] {
        theme.inks(for: tool.usesInk ? tool : .pen).map(PenColor.init)
    }

    /// The Pen Case's colours for `tool`: the user's, or the theme's inks. Tools that don't draw in a
    /// colour get the pen's.
    func quickColors(for tool: Tool) -> [PenColor] {
        if tool == .tape {
            return themeColors(for: .tape) // tape has its own colours, not the pens'
        }
        let kind = tool.penKind ?? .pen
        return penTray.tray[presets: kind].colors ?? themeColors(for: tool.usesInk ? tool : .pen)
    }

    /// Whether `tool`'s quick colours are the user's own.
    func hasCustomQuickColors(for tool: Tool) -> Bool {
        guard let kind = tool.penKind else { return false }
        return penTray.tray[presets: kind].colors != nil
    }

    /// Replaces quick colour `index` of `tool`.
    func setQuickColor(_ color: PenColor, at index: Int, for tool: Tool) {
        guard let kind = tool.penKind else { return }
        let defaults = themeColors(for: tool)
        penTray.update { $0.setQuickColor(color, at: index, for: kind, defaults: defaults) }
    }

    func resetQuickColors(for tool: Tool) {
        guard let kind = tool.penKind else { return }
        penTray.update { $0.resetQuickColors(for: kind) }
    }

    /// The colour `tool` draws in.
    func color(for tool: Tool) -> PenColor {
        settings[tool]?.color ?? quickColors(for: tool).first ?? PenColor(rgb: 0)
    }

    /// Makes `tool` draw in `color`. `remember` adds it to the recent colours (colours from the picker
    /// and the eyedropper; not the quick colours, which are always there anyway).
    func setColor(_ color: PenColor, for tool: Tool, remember: Bool = false) {
        guard tool.usesInk else { return }
        if tool == .text, textFormat != nil {
            formatText(.color(color)) // recolours the selected text, and what's typed next
        }
        var s = settings[tool] ?? ToolSettings(width: 4)
        s.color = color
        settings[tool] = s
        if remember {
            penTray.update { $0.addRecentColor(color) }
        }
    }

    /// A colour's name for VoiceOver: the theme ink's, or its hex code.
    func colorName(_ color: PenColor, for tool: Tool) -> String {
        theme.inks(for: tool.usesInk ? tool : .pen).first { PenColor($0) == color }?.name ?? "Color \(color.hex)"
    }

    // MARK: Pen tray

    /// What a pen tool draws with right now.
    struct CurrentPen: Equatable {
        let kind: PenKind
        let brush: BrushDescriptor
        let color: PenColor
        let width: Double
    }

    /// The pen `tool` is now: its brush, colour and width. Nil for tools that aren't pens.
    func currentPen(for tool: Tool) -> CurrentPen? {
        guard let kind = tool.penKind else { return nil }
        let brush = brush(for: tool)
        return CurrentPen(kind: kind, brush: brush, color: color(for: tool),
                          width: settings[tool]?.width ?? Double(brush.maxWidth))
    }

    /// Saves the current tool's pen to the end of the tray, named after its brush.
    @discardableResult
    func saveCurrentPen() -> SavedPen? {
        guard let pen = currentPen(for: tool) else { return nil }
        let saved = SavedPen(name: pen.brush.name, kind: pen.kind, brush: pen.brush, color: pen.color, width: pen.width)
        penTray.update { $0.add(saved) }
        return saved
    }

    /// Makes a saved pen's brush, colour and width the current ones and switches to its tool.
    func use(_ pen: SavedPen) {
        let tool = pen.kind.tool
        setBrush(pen.brush, for: tool, width: pen.width)
        settings[tool]?.color = pen.color
        select(tool)
    }

    /// Whether the current tool draws exactly as `pen` does.
    func isCurrent(_ pen: SavedPen) -> Bool {
        guard let now = currentPen(for: tool) else { return false }
        return now.kind == pen.kind && now.brush == pen.brush && now.color == pen.color && abs(now.width - pen.width) < 0.05
    }

    /// Overwrites a saved pen with the current tool's brush, colour and width.
    func updatePenToCurrent(_ pen: SavedPen) {
        guard let now = currentPen(for: tool) else { return }
        penTray.update { $0.updatePen(id: pen.id, kind: now.kind, brush: now.brush, color: now.color, width: now.width) }
    }

    // MARK: Brush editor

    /// Opens the brush editor on `tool`'s current brush.
    func editBrush(for tool: Tool) {
        guard tool.penKind != nil else { return }
        brushEditorTool = tool
    }

    /// Saves an edited brush and makes `tool` draw with it. A brush the user made is changed in place;
    /// editing a built-in brush, or a pen's, makes a new brush of the user's own.
    @discardableResult
    func saveEditedBrush(_ edited: BrushDescriptor, for tool: Tool) -> BrushDescriptor? {
        guard let kind = tool.penKind else { return nil }
        var brush = edited.clamped()
        if !isCustomBrush(brush, for: tool) {
            brush.id = UUID()
        }
        if brush.erases {
            brush.blend = .normal // an ink tool never erases
        }
        penTray.update { $0.saveBrush(brush, for: kind) }
        let saved = penTray.tray[presets: kind].brushes.first { $0.id == brush.id } ?? brush
        setBrush(saved, for: tool, width: Double(saved.maxWidth))
        return saved
    }

    /// Deletes one of the user's brushes. A tool drawing with it goes back to its default brush.
    func deleteCustomBrush(_ brush: BrushDescriptor, for tool: Tool) {
        guard let kind = tool.penKind, isCustomBrush(brush, for: tool) else { return }
        penTray.update { $0.removeBrush(id: brush.id, for: kind) }
        if self.brush(for: tool).id == brush.id {
            setBrush(Self.baseBrush(for: tool), for: tool, width: nil)
        }
    }

    // MARK: Pictures

    /// Puts pictures (image file bytes) on the current page and selects them.
    func insertImages(_ items: [Data]) {
        canvas?.insertImages(items)
    }

    /// Puts a photo (from the camera) on the current page.
    func insertImage(_ image: UIImage) {
        guard let data = CanvasView.fileData(for: image) else { return }
        insertImages([data])
    }

    /// Pastes the pasteboard's pictures onto the current page.
    func pasteImages() {
        canvas?.pasteImages()
    }

    /// Places a sticker in the middle of the visible part of the current page.
    func insertSticker(_ sticker: Sticker) {
        canvas?.insertSticker(sticker)
    }

    func imageCropDidChange(_ state: ImageCropState?) {
        if imageCrop != state {
            imageCrop = state
        }
    }

    func setImageCropMode(_ mode: ImageCropMode) {
        canvas?.setImageCropMode(mode)
    }

    func resetImageCrop() {
        canvas?.resetImageCrop()
    }

    func finishImageCrop(commit: Bool) {
        canvas?.finishImageCrop(commit: commit)
    }

    // MARK: Links

    /// What the link sheet is choosing a target for, while it's open.
    @Published var linkRequest: LinkRequest?
    /// The pages links were followed from in this editor, for Back.
    @Published var linkHistory = LinkHistory()
    /// Goes where a followed link points, from the page it was on. Set by the editor.
    var onFollowLink: ((LinkTarget, UUID) -> Void)?

    /// A link on the page `pageID` was tapped (or opened from its menu).
    func followLink(_ target: LinkTarget, from pageID: UUID) {
        onFollowLink?(target, pageID)
    }

    /// Opens the link sheet for a new link over the selection, or for a selected link.
    func requestLink(_ request: LinkRequest) {
        linkRequest = request
    }

    /// The link sheet chose `target`: puts the link on the page (or changes the one being edited).
    func applyLink(_ target: LinkTarget, title: String?) {
        guard let request = linkRequest else { return }
        linkRequest = nil
        canvas?.applyLink(request, target: target, title: title)
    }

    // MARK: Text

    /// The typeface and size of new text boxes (the text tool's options); their colour is the Pen Case's.
    @Published var newTextFont: TextFont = .sans
    @Published var newTextSize: CGFloat = 17
    /// The format at the caret of the text box being edited, while one is; the format bar shows it.
    @Published private(set) var textFormat: TextFormatState?

    /// How a new text box's text looks.
    var newTextStyle: TextStyle {
        TextStyle(font: newTextFont, size: newTextSize, color: color(for: .text))
    }

    func textFormatDidChange(_ state: TextFormatState?) {
        if textFormat != state {
            textFormat = state
        }
    }

    /// Changes the text box being edited (the selected text, or what's typed next).
    func formatText(_ change: TextFormatChange) {
        canvas?.formatText(change)
    }

    /// Finishes editing the text box, putting it on the page.
    func endTextEditing() {
        canvas?.endEditingText()
    }

    // MARK: Shapes

    /// Whether new shapes are drawn solid, dashed or dotted (the shape tool's options).
    @Published var shapeLineStyle: ShapeObject.LineStyle = .solid
    /// What new closed shapes are filled with; nil leaves them empty.
    @Published var shapeFill: PenColor?
    /// The style of the selected shapes (the first one's), while the selection holds any.
    @Published private(set) var selectedShapeStyle: ShapeStyle?

    /// How the shape tool draws a new shape: its colour and width, and the line style and fill.
    var newShapeStyle: ShapeStyle {
        ShapeStyle(color: color(for: .shape), lineWidth: CGFloat(settings[.shape]?.width ?? 3),
                   lineStyle: shapeLineStyle, fill: shapeFill)
    }

    /// The style of a shape a pen or pencil stroke snapped to: the stroke's colour, about the width the
    /// ink was drawing at, dashed or dotted if its brush is; no fill.
    func shapeStyle(snapping stroke: Stroke) -> ShapeStyle {
        let brush = stroke.brush
        let lineStyle: ShapeObject.LineStyle = !brush.dash.isActive ? .solid : brush.dash.on < 1 ? .dotted : .dashed
        let width = max((brush.size.lowerBound + brush.size.upperBound) / 2, 0.5)
        return ShapeStyle(color: PenColor(red: Double(stroke.color.r), green: Double(stroke.color.g),
                                          blue: Double(stroke.color.b)),
                          lineWidth: width, lineStyle: lineStyle)
    }

    func selectedShapesDidChange(_ style: ShapeStyle?) {
        if selectedShapeStyle != style {
            selectedShapeStyle = style
        }
    }

    /// Changes every selected shape's style, as one undoable edit.
    func restyleSelectedShapes(_ change: @escaping (inout ShapeStyle) -> Void) {
        canvas?.restyleSelectedShapes(change)
    }

    // MARK: Eyedropper

    /// Puts the canvas into eyedropper mode for `tool`'s colour (or one of its quick colours).
    func startEyedropper(for tool: Tool, quickColorIndex: Int?) {
        guard tool.usesInk else { return }
        eyedropper = EyedropperRequest(tool: tool, quickColorIndex: quickColorIndex)
    }

    /// The colour on screen at `point` in canvas-view coordinates (paper, template and ink as shown).
    func sampleColor(at point: CGPoint) -> PenColor? {
        if let continuousHost {
            return continuousHost.sampledColor(at: point)
        }
        return canvas?.sampledColor(at: point)
    }

    /// Ends eyedropper mode, using `color` if one was picked.
    func finishEyedropper(with color: PenColor?) {
        guard let request = eyedropper else { return }
        eyedropper = nil
        guard let color else { return }
        if let index = request.quickColorIndex {
            setQuickColor(color, at: index, for: request.tool)
        }
        setColor(color, for: request.tool, remember: true)
    }

    // MARK: New strokes

    /// Brush snapshot for a new stroke. `viewScale` converts the eraser's on-screen size to canvas units.
    func strokeTemplate(viewScale: CGFloat) -> StrokeTemplate {
        let s = current
        let base = brush(for: tool)
        if tool == .eraser {
            return StrokeTemplate(color: RGBA(r: 0, g: 0, b: 0),
                                  brush: base.sized(CGFloat(s.width) / viewScale, minimumRatio: 1))
        }
        // Pressure & Tilt settings adjust every ink brush, on top of its own character.
        return StrokeTemplate(color: color(for: tool).rgba,
                              brush: base.personalized(width: CGFloat(s.width),
                                                       minimumWidthRatio: CGFloat(minWidthRatio),
                                                       pressureExponent: CGFloat(pressureGamma),
                                                       tilt: tiltEnabled))
    }

    var simulatedAltitude: CGFloat {
        CGFloat(simulatedAltitudeDegrees) * .pi / 180
    }
}
