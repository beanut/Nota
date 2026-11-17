import UIKit

/// A canvas's input state, apart from the views: palm rejection, the finger-ink pressure model and the
/// samples waiting for refined estimates. `CanvasView+Input` feeds touches through it into `LiveStroke`.
struct CanvasInput {
    /// Palm rejection and finger drawing (see `PencilSettings`).
    var palmRejector = PalmRejector()
    /// Direct touches judged to be a resting hand; nothing on the canvas reacts to them.
    var palmTouches = Set<UITouch>()
    /// When the active stroke began, so a second finger landing soon after turns finger ink into a gesture.
    var strokeBeganAt: TimeInterval = 0
    /// The last finger-ink sample, for the pressure faked from drag speed.
    var fingerPrevious: FingerSample?
    /// Samples whose force or tilt are still estimates.
    var estimates = EstimateTracker()

    struct FingerSample {
        let location: CGPoint
        let time: TimeInterval
        let force: CGFloat
    }

    /// Finger ink (and the simulator's stand-in Pencil) has no pressure, so it's faked from drag speed:
    /// slow = heavy, fast = light, low-passed so the width changes smoothly. A predicted sample doesn't
    /// move the model on.
    mutating func fingerForce(at location: CGPoint, time: TimeInterval, predicted: Bool) -> CGFloat {
        var force: CGFloat = 0.6
        if let prev = fingerPrevious {
            force = prev.force
            let dt = time - prev.time
            if dt > 0 {
                let speed = location.distance(to: prev.location) / CGFloat(dt) // points per second
                let target = min(max(1 - speed / 2200, 0.1), 1)
                force = prev.force + (target - prev.force) * 0.2
            }
        }
        if !predicted {
            fingerPrevious = FingerSample(location: location, time: time, force: force)
        }
        return force
    }
}

/// The Pencil samples whose force and tilt were reported as estimates, keyed by the touch's
/// `estimationUpdateIndex`, until their refined values arrive (`touchesEstimatedPropertiesUpdated`).
struct EstimateTracker {
    /// A sample: which stroke, and which of its points.
    struct PointRef: Equatable {
        let strokeID: UUID
        let index: Int
    }

    /// More than this many unresolved samples and they're given up on (refinements that never came).
    static let limit = 1024

    private var points: [NSNumber: PointRef] = [:]
    private var outstanding: [UUID: Int] = [:]

    /// Samples still waiting for refined values.
    var count: Int {
        points.count
    }

    /// The point `key` refines, if it's still waiting.
    func point(for key: NSNumber) -> PointRef? {
        points[key]
    }

    /// Whether some of the stroke's samples still expect refined values.
    func isOutstanding(_ strokeID: UUID) -> Bool {
        (outstanding[strokeID] ?? 0) > 0
    }

    /// Point `index` of stroke `strokeID` expects refined values under `key`. A key already waiting for
    /// another point now stands for this one.
    mutating func expect(_ key: NSNumber, strokeID: UUID, index: Int) {
        if let old = points[key] {
            decrement(old.strokeID)
        }
        points[key] = PointRef(strokeID: strokeID, index: index)
        outstanding[strokeID, default: 0] += 1
    }

    /// The last refinement for `key` arrived.
    mutating func resolve(_ key: NSNumber) {
        guard let ref = points.removeValue(forKey: key) else { return }
        decrement(ref.strokeID)
    }

    /// Forgets every waiting sample once there are more than `limit` (a new stroke is starting).
    mutating func pruneIfOverflowing() {
        guard points.count > Self.limit else { return }
        points.removeAll()
        outstanding.removeAll()
    }

    private mutating func decrement(_ strokeID: UUID) {
        guard let count = outstanding[strokeID] else { return }
        if count <= 1 {
            outstanding.removeValue(forKey: strokeID)
        } else {
            outstanding[strokeID] = count - 1
        }
    }
}
