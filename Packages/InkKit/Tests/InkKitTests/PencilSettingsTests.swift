import CoreGraphics
import Foundation
@testable import InkKit
import Testing
import UIKit

@Suite("PencilSettings")
struct PencilSettingsTests {
    @Test("System Setting follows the system's preferred action")
    func systemActionResolves() {
        let system = PencilSettings.Action.system
        #expect(system.resolved(system: .switchEraser, fallback: .eraser) == .eraser)
        #expect(system.resolved(system: .switchPrevious, fallback: .eraser) == .previousTool)
        #expect(system.resolved(system: .showColorPalette, fallback: .eraser) == .palette)
        #expect(system.resolved(system: .showInkAttributes, fallback: .eraser) == .palette)
        #expect(system.resolved(system: .showContextualPalette, fallback: .eraser) == .palette)
        #expect(system.resolved(system: .ignore, fallback: .eraser) == .off)
        #expect(system.resolved(system: .runSystemShortcut, fallback: .palette) == .off)
    }

    @Test("A chosen action overrides the system's")
    func chosenActionWins() {
        for action in PencilSettings.Action.allCases where action != .system {
            #expect(action.resolved(system: .switchEraser, fallback: .palette) == action)
            #expect(action.resolved(system: .ignore, fallback: .palette) == action)
        }
    }

    @Test("Finger drawing follows Only Draw with Apple Pencil unless overridden")
    func fingerDrawing() {
        #expect(PencilSettings.FingerDrawing.system.fingerDraws(pencilOnlySystemSetting: false))
        #expect(!PencilSettings.FingerDrawing.system.fingerDraws(pencilOnlySystemSetting: true))
        #expect(!PencilSettings.FingerDrawing.pencilOnly.fingerDraws(pencilOnlySystemSetting: false))
        #expect(PencilSettings.FingerDrawing.fingerDraws.fingerDraws(pencilOnlySystemSetting: true))
    }

    @Test("Settings round-trip through UserDefaults")
    func persistence() throws {
        let suite = "PencilSettingsTests.\(UUID().uuidString)"
        let store = try #require(UserDefaults(suiteName: suite))
        defer { store.removePersistentDomain(forName: suite) }

        #expect(PencilSettings.load(from: store) == .defaults)
        var s = PencilSettings()
        s.doubleTap = .palette
        s.squeeze = .off
        s.fingerDrawing = .pencilOnly
        s.palmRejection = .high
        s.handedness = .left
        s.circleToSelect = false
        s.save(to: store)
        #expect(PencilSettings.load(from: store) == s)
    }

    @Test("Missing or unknown fields fall back to their defaults")
    func lenientDecoding() throws {
        let json = #"{"doubleTap":"previousTool","palmRejection":"extreme"}"#
        let s = try JSONDecoder().decode(PencilSettings.self, from: Data(json.utf8))
        #expect(s.doubleTap == .previousTool)
        #expect(s.palmRejection == .medium)
        #expect(s.squeeze == .system)
        #expect(s.circleToSelect)
    }

    @MainActor
    @Test("The controller loads and saves its settings")
    func controllerPersists() throws {
        let suite = "PencilSettingsTests.\(UUID().uuidString)"
        let store = try #require(UserDefaults(suiteName: suite))
        defer { store.removePersistentDomain(forName: suite) }

        let first = CanvasController(settingsStore: store)
        first.pencilSettings.handedness = .left
        let second = CanvasController(settingsStore: store)
        #expect(second.pencilSettings.handedness == .left)
    }

    @MainActor
    @Test("Gesture actions switch tools and toggle the palette")
    func performActions() throws {
        let suite = "PencilSettingsTests.\(UUID().uuidString)"
        let store = try #require(UserDefaults(suiteName: suite))
        defer { store.removePersistentDomain(forName: suite) }
        let c = CanvasController(settingsStore: store)
        c.select(.pencil)
        c.perform(.eraser, at: .zero)
        #expect(c.tool == .eraser)
        c.perform(.eraser, at: .zero)
        #expect(c.tool == .pencil)
        c.select(.highlighter)
        c.perform(.previousTool, at: .zero)
        #expect(c.tool == .pencil)
        c.perform(.palette, at: CGPoint(x: 10, y: 20))
        #expect(c.quickPaletteLocation == CGPoint(x: 10, y: 20))
        c.perform(.palette, at: CGPoint(x: 10, y: 20))
        #expect(c.quickPaletteLocation == nil)
        c.perform(.off, at: .zero)
        #expect(c.tool == .pencil)
    }

    // MARK: Palette placement

    let screen = CGRect(x: 0, y: 0, width: 1024, height: 1366)
    let palette = CGSize(width: 400, height: 50)

    @Test("The palette opens above the tip, away from the writing hand")
    func paletteAwayFromHand() {
        let tip = CGPoint(x: 600, y: 700)
        let right = PencilSettings.paletteCenter(anchor: tip, size: palette, in: screen, handedness: .right)
        let left = PencilSettings.paletteCenter(anchor: tip, size: palette, in: screen, handedness: .left)
        #expect(right.x + palette.width / 2 < tip.x) // wholly left of the tip
        #expect(left.x - palette.width / 2 > tip.x) // wholly right of it
        #expect(right.y + palette.height / 2 < tip.y)
        #expect(left.y == right.y)
    }

    @Test("The palette stays on screen")
    func paletteClamped() {
        let nearTopLeft = PencilSettings.paletteCenter(anchor: CGPoint(x: 30, y: 20), size: palette, in: screen,
                                                       handedness: .right)
        #expect(nearTopLeft.x - palette.width / 2 >= 16)
        #expect(nearTopLeft.y > 20) // no room above: it drops below the tip
        let nearRight = PencilSettings.paletteCenter(anchor: CGPoint(x: 1010, y: 700), size: palette, in: screen,
                                                     handedness: .left)
        #expect(nearRight.x + palette.width / 2 <= screen.maxX - 16)
    }
}

@Suite("PalmRejector")
struct PalmRejectorTests {
    @Test("A large contact is a palm at any time")
    func largeContact() {
        let r = PalmRejector(sensitivity: .medium, handedness: .right)
        #expect(r.rejects(location: .zero, radius: 40, time: 100))
        #expect(!r.rejects(location: .zero, radius: 12, time: 100))
    }

    @Test("Sensitivity sets the largest finger")
    func sensitivityThresholds() {
        let radius: CGFloat = 28
        #expect(!PalmRejector(sensitivity: .low).rejects(location: .zero, radius: radius, time: 0))
        #expect(!PalmRejector(sensitivity: .medium).rejects(location: .zero, radius: radius, time: 0))
        #expect(PalmRejector(sensitivity: .high).rejects(location: .zero, radius: radius, time: 0))
    }

    @Test("Just after the Pencil, touches on the writing hand's side are ignored")
    func handSideAfterPencil() {
        var r = PalmRejector(sensitivity: .medium, handedness: .right)
        let tip = CGPoint(x: 500, y: 500)
        r.pencilSeen(at: tip, time: 10)
        let belowRight = CGPoint(x: 600, y: 650)
        let farLeft = CGPoint(x: 200, y: 650)
        let wellAbove = CGPoint(x: 600, y: 300)
        #expect(r.rejects(location: belowRight, radius: 12, time: 10.2))
        #expect(!r.rejects(location: farLeft, radius: 12, time: 10.2)) // the other hand
        #expect(!r.rejects(location: wellAbove, radius: 12, time: 10.2))
        #expect(!r.rejects(location: belowRight, radius: 12, time: 11)) // the cooldown has passed
    }

    @Test("Left-handed mode mirrors the hand's side")
    func leftHanded() {
        var r = PalmRejector(sensitivity: .medium, handedness: .left)
        r.pencilSeen(at: CGPoint(x: 500, y: 500), time: 10)
        #expect(r.rejects(location: CGPoint(x: 400, y: 650), radius: 12, time: 10.2))
        #expect(!r.rejects(location: CGPoint(x: 800, y: 650), radius: 12, time: 10.2))
    }
}
