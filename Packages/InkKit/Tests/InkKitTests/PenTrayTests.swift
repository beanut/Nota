import CoreGraphics
import Foundation
@testable import InkKit
import QuartzCore
import Testing

// MARK: - PenColor

@Suite("PenColor")
struct PenColorTests {
    @Test("Hex codes parse and print")
    func hex() {
        #expect(PenColor(hex: "#3345D9")?.rgb == 0x3345D9)
        #expect(PenColor(hex: "3345d9")?.rgb == 0x3345D9)
        #expect(PenColor(hex: " #fa0 ")?.rgb == 0xFFAA00)
        #expect(PenColor(hex: "#12345") == nil)
        #expect(PenColor(hex: "#GG0000") == nil)
        #expect(PenColor(hex: "") == nil)
        #expect(PenColor(rgb: 0x0A0B0C).hex == "#0A0B0C")
        #expect(PenColor(rgb: 0xFF12_3456).rgb == 0x123456)
    }

    @Test("Components round to 8 bits, so equal colours are equal however they're made")
    func components() {
        let ink = InkColor(name: "Blue", hex: 0x3345D9)
        #expect(PenColor(ink) == PenColor(rgb: 0x3345D9))
        #expect(PenColor(red: 1, green: 0.5, blue: .nan).rgb == 0xFF8000)
        #expect(PenColor(red: 2, green: -1, blue: 0).rgb == 0xFF0000)
    }

    @Test("HSB converts both ways")
    func hsb() {
        #expect(PenColor(hue: 0, saturation: 1, brightness: 1).rgb == 0xFF0000)
        #expect(PenColor(hue: 1.0 / 3, saturation: 1, brightness: 1).rgb == 0x00FF00)
        #expect(PenColor(hue: 2.0 / 3, saturation: 1, brightness: 1).rgb == 0x0000FF)
        #expect(PenColor(hue: 0.5, saturation: 0, brightness: 0.5).rgb == 0x808080)
        #expect(PenColor(hue: 1, saturation: 1, brightness: 1).rgb == 0xFF0000) // hue wraps
        for rgb: UInt32 in [0x3345D9, 0x12786B, 0xC04C1A, 0xF7C600, 0x7C3AED, 0x1A1A1F] {
            let c = PenColor(rgb: rgb)
            let hsb = c.hsb
            let back = PenColor(hue: hsb.hue, saturation: hsb.saturation, brightness: hsb.brightness)
            // Within one step per channel.
            #expect(abs(Int(back.rgb >> 16) - Int(rgb >> 16)) <= 1)
            #expect(abs(Int((back.rgb >> 8) & 0xFF) - Int((rgb >> 8) & 0xFF)) <= 1)
            #expect(abs(Int(back.rgb & 0xFF) - Int(rgb & 0xFF)) <= 1)
        }
    }

    @Test("Encodes as a hex string")
    func codable() throws {
        let data = try JSONEncoder().encode([PenColor(rgb: 0x3345D9)])
        #expect(String(bytes: data, encoding: .utf8) == "[\"#3345D9\"]")
        #expect(try JSONDecoder().decode([PenColor].self, from: data) == [PenColor(rgb: 0x3345D9)])
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(PenColor.self, from: Data("\"red\"".utf8)) }
    }
}

// MARK: - PenTray

@Suite("PenTray")
struct PenTrayTests {
    private func pen(_ name: String, kind: PenKind = .pen, brush: BrushDescriptor = .pen,
                     color: UInt32 = 0x1A1A1F, width: Double = 4) -> SavedPen {
        SavedPen(name: name, kind: kind, brush: brush, color: PenColor(rgb: color), width: width,
                 modifiedAt: Date(timeIntervalSince1970: 1_000_000))
    }

    @Test("Pens are added, renamed, updated and removed")
    func pens() {
        var tray = PenTray()
        let a = pen("  Blue Fountain  ", brush: .fountainPen, color: 0x3345D9)
        tray.add(a)
        tray.add(pen("", brush: .marker))
        #expect(tray.pens.map(\.name) == ["Blue Fountain", "Marker"]) // trimmed; blank takes the brush's name
        tray.renamePen(id: a.id, to: "   ")
        #expect(tray.pens[0].name == "Blue Fountain")
        tray.renamePen(id: a.id, to: String(repeating: "x", count: 100))
        #expect(tray.pens[0].name.count == PenTray.maxNameLength)
        tray.updatePen(id: a.id, kind: .highlighter, brush: .highlighter, color: PenColor(rgb: 0xF7C600), width: 20)
        #expect(tray.pens[0].kind == .highlighter && tray.pens[0].width == 20 && tray.pens[0].id == a.id)
        tray.add(tray.pens[0]) // the same id again replaces, at the end
        #expect(tray.pens.count == 2 && tray.pens[1].id == a.id)
        tray.removePen(id: a.id)
        #expect(tray.pens.map(\.name) == ["Marker"])
    }

    @Test("Moving pens follows List's onMove")
    func move() {
        var tray = PenTray()
        for name in ["A", "B", "C", "D"] {
            tray.add(pen(name))
        }
        tray.movePens(fromOffsets: [0], toOffset: 3)
        #expect(tray.pens.map(\.name) == ["B", "C", "A", "D"])
        tray.movePens(fromOffsets: [3], toOffset: 0)
        #expect(tray.pens.map(\.name) == ["D", "B", "C", "A"])
        tray.movePens(fromOffsets: [0, 2], toOffset: 4)
        #expect(tray.pens.map(\.name) == ["B", "A", "D", "C"])
        tray.movePens(fromOffsets: [9], toOffset: 0) // out of range: nothing
        #expect(tray.pens.map(\.name) == ["B", "A", "D", "C"])
        tray.movePen(id: tray.pens[0].id, by: 1)
        #expect(tray.pens.map(\.name) == ["A", "B", "D", "C"])
        tray.movePen(id: tray.pens[0].id, by: -1) // already first
        #expect(tray.pens.map(\.name) == ["A", "B", "D", "C"])
    }

    @Test("Quick sizes and colours start from the defaults and reset")
    func quickPresets() {
        var tray = PenTray()
        tray.setQuickSize(5, at: 1, for: .pen, defaults: [2, 4, 8])
        #expect(tray[presets: .pen].sizes == [2, 5, 8])
        tray.setQuickSize(.nan, at: 0, for: .pen, defaults: [2, 4, 8])
        tray.setQuickSize(3, at: 7, for: .pen, defaults: [2, 4, 8])
        #expect(tray[presets: .pen].sizes == [2, 5, 8])
        #expect(tray[presets: .pencil].sizes == nil)
        tray.resetQuickSizes(for: .pen)
        #expect(tray[presets: .pen].sizes == nil)

        let defaults = [0x111111, 0x222222, 0x333333].map { PenColor(rgb: $0) }
        tray.setQuickColor(PenColor(rgb: 0xABCDEF), at: 2, for: .highlighter, defaults: defaults)
        #expect(tray[presets: .highlighter].colors?.map(\.rgb) == [0x111111, 0x222222, 0xABCDEF])
        tray.resetQuickColors(for: .highlighter)
        #expect(tray[presets: .highlighter].colors == nil)
    }

    @Test("Recent colours are newest first, without repeats, capped")
    func recents() {
        var tray = PenTray()
        for rgb in 0 ..< UInt32(20) {
            tray.addRecentColor(PenColor(rgb: rgb))
        }
        #expect(tray.recentColors.count == PenTray.maxRecentColors)
        #expect(tray.recentColors.first == PenColor(rgb: 19))
        tray.addRecentColor(PenColor(rgb: 15))
        #expect(tray.recentColors.first == PenColor(rgb: 15))
        #expect(tray.recentColors.filter { $0 == PenColor(rgb: 15) }.count == 1)
    }

    @Test("Palettes hold unique colours")
    func palettes() {
        var tray = PenTray()
        let id = tray.addPalette(named: " ", colors: [PenColor(rgb: 1)])
        #expect(tray.palettes[0].name == "Palette 1")
        tray.addColor(PenColor(rgb: 2), toPalette: id)
        tray.addColor(PenColor(rgb: 2), toPalette: id)
        #expect(tray.palettes[0].colors == [PenColor(rgb: 1), PenColor(rgb: 2)])
        tray.removeColor(PenColor(rgb: 1), fromPalette: id)
        #expect(tray.palettes[0].colors == [PenColor(rgb: 2)])
        tray.renamePalette(id: id, to: "Diagrams")
        #expect(tray.palettes[0].name == "Diagrams")
        tray.removePalette(id: id)
        #expect(tray.palettes.isEmpty)
    }

    @Test("Custom brushes are saved clamped, replaced by id and removed")
    func brushes() {
        var tray = PenTray()
        var brush = BrushDescriptor.fountainPen
        brush.id = UUID()
        brush.opacity = 7
        tray.saveBrush(brush, for: .pen)
        #expect(tray[presets: .pen].brushes.first?.opacity == 1)
        brush.name = "Inky"
        tray.saveBrush(brush, for: .pen)
        #expect(tray[presets: .pen].brushes.map(\.name) == ["Inky"])
        tray.removeBrush(id: brush.id, for: .pen)
        #expect(tray[presets: .pen].brushes.isEmpty)
    }

    @Test("A tray survives JSON exactly")
    func roundTrip() throws {
        var tray = PenTray()
        tray.add(pen("Blue", brush: .fountainPen, color: 0x3345D9, width: 5.5))
        tray.add(pen("Yellow", kind: .highlighter, brush: .chiselHighlighter, color: 0xF7C600, width: 22))
        tray.setQuickSize(6, at: 2, for: .pencil, defaults: [2, 3, 6.5])
        tray.setQuickColor(PenColor(rgb: 0x123456), at: 0, for: .pen, defaults: [PenColor(rgb: 0), PenColor(rgb: 1)])
        var custom = BrushDescriptor.brushPen
        custom.id = UUID()
        custom.name = "Wet Brush"
        custom.wetness = 0.8
        tray.saveBrush(custom, for: .pen)
        let paletteID = tray.addPalette(named: "Biology", colors: [PenColor(rgb: 0x2B8A3E)],
                                        at: Date(timeIntervalSince1970: 2_000_000))
        tray.palettes[0].modifiedAt = Date(timeIntervalSince1970: 2_000_000)
        tray.addRecentColor(PenColor(rgb: 0xC04C1A))
        let data = try tray.jsonData()
        let decoded = try PenTray(json: data)
        #expect(decoded == tray)
        #expect(decoded.palettes.first?.id == paletteID)
        #expect(try decoded.jsonData() == data) // stable bytes
        let json = try #require(String(bytes: data, encoding: .utf8))
        #expect(json.contains("\"version\" : 1"))
        #expect(json.contains("\"#3345D9\""))
    }

    @Test("Decoding keeps whatever it can read")
    func lenient() throws {
        let json = """
        {
          "version": 99,
          "futureField": true,
          "pens": [
            {"id": "6E6F7461-0000-4000-8000-0000000000AA", "name": "Good", "kind": "pencil",
             "brush": {"name": "HB", "size": [0.75, 3]}, "color": "#123456", "width": 3},
            {"name": "Unknown kind", "kind": "crayon", "brush": {}, "color": "#123456"},
            {"name": "Bad colour", "kind": "pen", "brush": {}, "color": "blue"},
            {"kind": "pen", "brush": {"opacity": 40}, "color": "#000", "width": "wide"}
          ],
          "presets": {"pen": {"sizes": [1, 2], "colors": ["#FF0000", "nope", "#00FF00"]},
                      "highlighter": {"sizes": [10, 20, 30]}},
          "palettes": [{"name": "P", "colors": ["#ABCDEF", 7]}, 5],
          "recentColors": ["#111111", "#111111", "nope", "#222222"]
        }
        """
        let tray = try PenTray(json: Data(json.utf8))
        #expect(tray.pens.map(\.name) == ["Good", "Pen"])
        #expect(tray.pens[0].kind == .pencil && tray.pens[0].color.rgb == 0x123456)
        #expect(tray.pens[1].brush.opacity == 1 && tray.pens[1].width == 4) // clamped and defaulted
        #expect(tray[presets: .pen].sizes == nil) // not three sizes
        #expect(tray[presets: .pen].colors == [PenColor(rgb: 0xFF0000), PenColor(rgb: 0x00FF00)])
        #expect(tray[presets: .highlighter].sizes == [10, 20, 30])
        #expect(tray.palettes.count == 1 && tray.palettes[0].colors == [PenColor(rgb: 0xABCDEF)])
        #expect(tray.recentColors == [PenColor(rgb: 0x111111), PenColor(rgb: 0x222222)])
        #expect(try PenTray(json: Data("{}".utf8)) == PenTray())
        #expect(throws: (any Error).self) { try PenTray(json: Data("[1]".utf8)) }
    }
}

// MARK: - PenTrayStore

@MainActor
@Suite("PenTrayStore")
struct PenTrayStoreTests {
    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("PenTrayStoreTests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("PenTray.json")
    }

    @Test("Every change is saved, and a new store (a relaunch) reads it back")
    func persists() {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = PenTrayStore(fileURL: url)
        #expect(store.tray == PenTray())
        #expect(!FileManager.default.fileExists(atPath: url.path)) // nothing written until something changes
        let pen = SavedPen(name: "Mine", kind: .pen, brush: .fountainPen, color: PenColor(rgb: 0x3345D9), width: 5)
        store.update { $0.add(pen) }
        store.update { $0.addRecentColor(PenColor(rgb: 0x3345D9)) }
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(store.lastSaveError == nil)

        let relaunched = PenTrayStore(fileURL: url)
        #expect(relaunched.tray == store.tray)
        #expect(relaunched.tray.pens.first?.brush == .fountainPen)
    }

    @Test("An unreadable file is moved aside, not overwritten")
    func unreadable() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: url)
        let store = PenTrayStore(fileURL: url)
        #expect(store.tray == PenTray())
        let aside = url.deletingLastPathComponent().appendingPathComponent("PenTray.unreadable.json")
        #expect(try Data(contentsOf: aside) == Data("not json".utf8))
    }

    @Test("A store without a file keeps the tray in memory")
    func inMemory() {
        let store = PenTrayStore(fileURL: nil)
        store.update { $0.addRecentColor(PenColor(rgb: 1)) }
        #expect(store.tray.recentColors == [PenColor(rgb: 1)])
        store.reload()
        #expect(store.tray == PenTray())
    }
}

// MARK: - Controller

@MainActor
@Suite("Pen tray in the editor")
struct PenTrayControllerTests {
    /// A controller with an in-memory tray. Pencil settings go to a throwaway defaults suite (`defaults`).
    private func controller() throws -> CanvasController {
        try CanvasController(settingsStore: #require(UserDefaults(suiteName: suite)), penTray: PenTrayStore(fileURL: nil))
    }

    private let suite = "PenTrayControllerTests"

    @Test("Quick colours come from the theme until the user changes one")
    func quickColors() throws {
        let c = try controller()
        let pens = InkTheme.standardPenInks.map(PenColor.init)
        #expect(c.quickColors(for: .pen) == pens)
        #expect(c.quickColors(for: .highlighter) == InkTheme.standardHighlighterInks.map(PenColor.init))
        #expect(c.quickColors(for: .eraser) == pens)
        #expect(c.color(for: .pen) == pens[0])
        #expect(c.colorName(pens[1], for: .pen) == "Blue")
        #expect(c.colorName(PenColor(rgb: 0xABCDEF), for: .pen) == "Color #ABCDEF")

        c.setQuickColor(PenColor(rgb: 0xABCDEF), at: 1, for: .pen)
        #expect(c.quickColors(for: .pen)[1] == PenColor(rgb: 0xABCDEF))
        #expect(c.quickColors(for: .pencil) == pens) // per tool
        #expect(c.hasCustomQuickColors(for: .pen))
        c.resetQuickColors(for: .pen)
        #expect(c.quickColors(for: .pen) == pens)
    }

    @Test("A picked colour draws, and is remembered only when it came from the picker")
    func colors() throws {
        let c = try controller()
        c.setColor(PenColor(rgb: 0x0A5BD6), for: .pen)
        #expect(c.penTray.tray.recentColors.isEmpty)
        c.setColor(PenColor(rgb: 0x12786B), for: .pen, remember: true)
        #expect(c.penTray.tray.recentColors == [PenColor(rgb: 0x12786B)])
        #expect(c.strokeTemplate(viewScale: 1).color == PenColor(rgb: 0x12786B).rgba)
        c.setColor(PenColor(rgb: 0xFF0000), for: .eraser) // no colour for the eraser
        #expect(c.settings[.eraser]?.color == nil)
    }

    @Test("Quick sizes are the defaults until one is set to the current width")
    func quickSizes() throws {
        let c = try controller()
        #expect(c.quickSizes(for: .pen) == CanvasController.widthPresets(for: .pen))
        c.settings[.pen]?.width = 11
        c.setQuickSize(at: 2, for: .pen)
        #expect(c.quickSizes(for: .pen) == [2, 4, 11])
        #expect(c.quickSizes(for: .eraser) == CanvasController.widthPresets(for: .eraser))
        c.resetQuickSizes(for: .pen)
        #expect(c.quickSizes(for: .pen) == [2, 4, 8])
    }

    @Test("Saving and using a pen brings back its tool, brush, colour and width")
    func savedPens() throws {
        let c = try controller()
        c.select(.highlighter)
        c.selectBrush(.chiselHighlighter, for: .highlighter)
        c.setColor(PenColor(rgb: 0x5ED17A), for: .highlighter)
        c.settings[.highlighter]?.width = 30
        let saved = try #require(c.saveCurrentPen())
        #expect(saved.name == "Chisel Highlighter" && saved.kind == .highlighter && saved.width == 30)
        #expect(c.isCurrent(saved))

        c.select(.pen)
        #expect(!c.isCurrent(saved))
        c.selectBrush(.chiselHighlighter, for: .highlighter) // already
        c.select(.lasso)
        #expect(c.saveCurrentPen() == nil) // the lasso isn't a pen

        c.settings[.highlighter]?.width = 12
        c.use(saved)
        #expect(c.tool == .highlighter && c.isCurrent(saved))
        let template = c.strokeTemplate(viewScale: 1)
        #expect(template.brush.id == BrushDescriptor.chiselHighlighter.id && template.brush.maxWidth == 30)
        #expect(template.color == PenColor(rgb: 0x5ED17A).rgba)

        c.settings[.highlighter]?.width = 40
        c.updatePenToCurrent(saved)
        #expect(c.penTray.tray.pens.first?.width == 40)
    }

    @Test("A pen whose brush was deleted still draws with its own copy")
    func penOutlivesBrush() throws {
        let c = try controller()
        var edited = BrushDescriptor.fountainPen
        edited.wetness = 0.9
        let brush = try #require(c.saveEditedBrush(edited, for: .pen))
        let pen = try #require(c.saveCurrentPen())
        c.deleteCustomBrush(brush, for: .pen)
        #expect(c.brush(for: .pen) == .pen) // the tool falls back
        c.use(pen)
        #expect(c.brush(for: .pen).wetness == 0.9)
    }

    @Test("Editing a built-in brush makes a new one; editing the user's own changes it in place")
    func editedBrushes() throws {
        let c = try controller()
        var edited = BrushDescriptor.fountainPen
        edited.name = "Broad Nib"
        edited.size = 3 ... 7
        edited.blend = .destinationOut // never allowed for an ink tool
        let saved = try #require(c.saveEditedBrush(edited, for: .pen))
        #expect(saved.id != BrushDescriptor.fountainPen.id && saved.blend == .normal)
        #expect(c.availableBrushes(for: .pen).last == saved)
        #expect(c.availableBrushes(for: .pencil) == BrushDescriptor.pencils)
        #expect(c.brush(for: .pen) == saved && c.settings[.pen]?.width == 7)
        #expect(BrushDescriptor.fountainPen.name == "Fountain Pen") // the built-in is untouched

        var again = saved
        again.name = "Broader Nib"
        let resaved = try #require(c.saveEditedBrush(again, for: .pen))
        #expect(resaved.id == saved.id)
        #expect(c.availableBrushes(for: .pen).filter { c.isCustomBrush($0, for: .pen) }.map(\.name) == ["Broader Nib"])

        c.selectBrush(.pen, for: .pen)
        c.selectBrush(resaved, for: .pen) // the user's brushes can be picked like built-in ones
        #expect(c.brush(for: .pen) == resaved)
        c.deleteCustomBrush(resaved, for: .pen)
        #expect(c.brush(for: .pen) == .pen)
        #expect(c.availableBrushes(for: .pen) == BrushDescriptor.pens)
    }

    @Test("The eyedropper sets the colour, and the quick colour it was opened from")
    func eyedropper() throws {
        let c = try controller()
        c.startEyedropper(for: .eraser, quickColorIndex: nil)
        #expect(c.eyedropper == nil)
        c.startEyedropper(for: .pen, quickColorIndex: 3)
        c.finishEyedropper(with: nil) // cancelled
        #expect(c.eyedropper == nil && !c.hasCustomQuickColors(for: .pen))
        c.startEyedropper(for: .pen, quickColorIndex: 3)
        c.finishEyedropper(with: PenColor(rgb: 0x445566))
        #expect(c.quickColors(for: .pen)[3] == PenColor(rgb: 0x445566))
        #expect(c.color(for: .pen) == PenColor(rgb: 0x445566))
        #expect(c.penTray.tray.recentColors == [PenColor(rgb: 0x445566)])
    }

    @Test("Eyedropper sampling reads the colour drawn at a point")
    func sampling() {
        let root = CALayer()
        root.frame = CGRect(x: 0, y: 0, width: 100, height: 100)
        root.backgroundColor = CGColor(srgbRed: 0.2, green: 0.4, blue: 0.6, alpha: 1)
        let square = CALayer()
        square.frame = CGRect(x: 50, y: 0, width: 50, height: 20)
        square.backgroundColor = CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
        root.addSublayer(square)
        #expect(Eyedropper.sample(root, at: CGPoint(x: 10, y: 10)) == PenColor(red: 0.2, green: 0.4, blue: 0.6))
        #expect(Eyedropper.sample(root, at: CGPoint(x: 70, y: 5)) == PenColor(rgb: 0xFF0000)) // top right
        #expect(Eyedropper.sample(root, at: CGPoint(x: 70, y: 50)) == PenColor(red: 0.2, green: 0.4, blue: 0.6))
        // At 2× and 3×, the pixel just inside the square's edge is red and the one just outside isn't.
        #expect(Eyedropper.sample(root, at: CGPoint(x: 50.1, y: 19.6), scale: 2) == PenColor(rgb: 0xFF0000))
        #expect(Eyedropper.sample(root, at: CGPoint(x: 49.7, y: 10), scale: 3) == PenColor(red: 0.2, green: 0.4, blue: 0.6))
    }
}
