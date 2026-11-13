import CoreGraphics
import Foundation
import UIKit

/// How the Apple Pencil and fingers behave on the canvas: what double-tap and squeeze do, whether a
/// finger draws, how hard palms are rejected, which hand holds the Pencil and the scribble gestures.
///
/// Saved to `UserDefaults` by `CanvasController`, so every editor and window shares one set.
struct PencilSettings: Equatable, Codable {
    /// What a double-tap or squeeze does.
    enum Action: String, CaseIterable, Identifiable, Codable {
        /// Whatever Settings › Apple Pencil asks for.
        case system
        /// Switch between the current tool and the eraser.
        case eraser
        /// Switch back to the tool used before this one.
        case previousTool
        /// Show the quick palette (tools and inks) at the Pencil.
        case palette
        /// Do nothing.
        case off

        var id: String {
            rawValue
        }

        /// What to do when the system asks for `preferred`: the user's choice, or for `.system` the
        /// system's, with `fallback` for actions this canvas doesn't have. Never returns `.system`.
        func resolved(system preferred: UIPencilPreferredAction, fallback: Action) -> Action {
            guard self == .system else { return self }
            switch preferred {
            case .ignore, .runSystemShortcut: return .off // the system runs the shortcut itself
            case .switchEraser: return .eraser
            case .switchPrevious: return .previousTool
            case .showColorPalette, .showInkAttributes, .showContextualPalette: return .palette
            @unknown default: return fallback == .system ? .off : fallback
            }
        }
    }

    /// Whether a finger draws, or only pans, zooms and taps.
    enum FingerDrawing: String, CaseIterable, Identifiable, Codable {
        /// Follow Settings › Apple Pencil › Only Draw with Apple Pencil.
        case system
        case pencilOnly
        case fingerDraws

        var id: String {
            rawValue
        }

        /// `pencilOnlySystemSetting` is `UIPencilInteraction.prefersPencilOnlyDrawing`.
        func fingerDraws(pencilOnlySystemSetting: Bool) -> Bool {
            switch self {
            case .system: !pencilOnlySystemSetting
            case .pencilOnly: false
            case .fingerDraws: true
            }
        }
    }

    /// How eagerly a resting hand is ignored. Higher rejects more palms but also more real fingers.
    enum PalmRejection: String, CaseIterable, Identifiable, Codable {
        case low, medium, high

        var id: String {
            rawValue
        }

        /// A direct touch reporting a larger contact radius than this (points) is a palm, not a finger.
        var maxFingerRadius: CGFloat {
            switch self {
            case .low: 45
            case .medium: 32
            case .high: 24
            }
        }

        /// For this long after the Pencil was last on or over the glass, touches on the writing hand's
        /// side of it are ignored too.
        var pencilCooldown: TimeInterval {
            switch self {
            case .low: 0.2
            case .medium: 0.5
            case .high: 1.0
            }
        }

        /// How far (points) onto the other side of the Pencil the writing hand's zone reaches.
        var handSlop: CGFloat {
            switch self {
            case .low: 40
            case .medium: 80
            case .high: 140
            }
        }
    }

    enum Handedness: String, CaseIterable, Identifiable, Codable {
        case right, left

        var id: String {
            rawValue
        }
    }

    var doubleTap: Action = .system
    var squeeze: Action = .system
    var fingerDrawing: FingerDrawing = .system
    var palmRejection: PalmRejection = .medium
    var handedness: Handedness = .right
    /// Scribbling back and forth over ink erases it.
    var scratchOutToErase = true
    /// Drawing a loop around ink and holding the Pencil still selects it.
    var circleToSelect = true

    init() {}

    /// Reads each field on its own, so settings saved by an older build keep the fields it knew.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = PencilSettings.defaults
        doubleTap = (try? c.decode(Action.self, forKey: .doubleTap)) ?? d.doubleTap
        squeeze = (try? c.decode(Action.self, forKey: .squeeze)) ?? d.squeeze
        fingerDrawing = (try? c.decode(FingerDrawing.self, forKey: .fingerDrawing)) ?? d.fingerDrawing
        palmRejection = (try? c.decode(PalmRejection.self, forKey: .palmRejection)) ?? d.palmRejection
        handedness = (try? c.decode(Handedness.self, forKey: .handedness)) ?? d.handedness
        scratchOutToErase = (try? c.decode(Bool.self, forKey: .scratchOutToErase)) ?? d.scratchOutToErase
        circleToSelect = (try? c.decode(Bool.self, forKey: .circleToSelect)) ?? d.circleToSelect
    }

    static let defaults = PencilSettings()
    static let defaultsKey = "InkKit.pencilSettings"

    static func load(from store: UserDefaults = .standard) -> PencilSettings {
        guard let data = store.data(forKey: defaultsKey),
              let settings = try? JSONDecoder().decode(PencilSettings.self, from: data) else { return .defaults }
        return settings
    }

    func save(to store: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) {
            store.set(data, forKey: Self.defaultsKey)
        }
    }

    /// Where to centre the quick palette of `size` for a Pencil at `anchor`: above the tip and to the
    /// side away from the writing hand (the barrel leans towards it), kept `margin` inside `bounds`.
    static func paletteCenter(anchor: CGPoint, size: CGSize, in bounds: CGRect, handedness: Handedness,
                              gap: CGFloat = 24, margin: CGFloat = 16) -> CGPoint {
        let away: CGFloat = handedness == .right ? -1 : 1
        var x = anchor.x + away * (gap + size.width / 2)
        var y = anchor.y - gap - size.height / 2
        let minX = bounds.minX + margin + size.width / 2, maxX = bounds.maxX - margin - size.width / 2
        let minY = bounds.minY + margin + size.height / 2, maxY = bounds.maxY - margin - size.height / 2
        x = minX <= maxX ? min(max(x, minX), maxX) : bounds.midX
        if y < minY {
            y = anchor.y + gap + size.height / 2 // no room above: below the tip instead
        }
        y = minY <= maxY ? min(max(y, minY), maxY) : bounds.midY
        return CGPoint(x: x, y: y)
    }
}

/// Decides whether a finger touch is a resting palm: by its contact size, and by where it lands
/// relative to the Pencil just after the Pencil was on or over the glass.
struct PalmRejector {
    var sensitivity: PencilSettings.PalmRejection = .medium
    var handedness: PencilSettings.Handedness = .right
    private(set) var lastPencil: (location: CGPoint, time: TimeInterval)?

    /// The Pencil touched or hovered at `location` (view points) at `time` (the `UITouch` clock).
    mutating func pencilSeen(at location: CGPoint, time: TimeInterval) {
        lastPencil = (location, time)
    }

    /// Whether a direct touch at `location` with contact radius `radius` should be ignored.
    func rejects(location: CGPoint, radius: CGFloat, time: TimeInterval) -> Bool {
        if radius > sensitivity.maxFingerRadius {
            return true
        }
        guard let pencil = lastPencil, time - pencil.time <= sensitivity.pencilCooldown else { return false }
        // The writing hand rests below the tip and to its side: right of it for the right hand.
        let dx = location.x - pencil.location.x, dy = location.y - pencil.location.y
        let slop = sensitivity.handSlop
        let onHandSide = handedness == .right ? dx > -slop : dx < slop
        return onHandSide && dy > -slop
    }
}
